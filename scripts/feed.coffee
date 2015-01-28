# Description:
#

cronJob = require('cron').CronJob
_     = require 'underscore'
_.str = require 'underscore.string'
async = require 'asyncawait/async'
await = require 'asyncawait/await'
util  = require 'util'
Promise = require 'bluebird'
request = Promise.promisifyAll(require('request'))
fs      = Promise.promisifyAll(require('fs'))

class Feedly
  authInfo = {}
  authHeader = {}
  refreshRequestOptions = {}

  constructor: () ->
    authInfo =
      access_token:  process.env.FEEDLY_ACCESS_TOKEN

    authHeader =
        Authorization: "Bearer " + authInfo.access_token

  fetchFeeds: () ->
    request.getAsync(
      url: 'https://cloud.feedly.com/v3/markers/counts'
      headers: authHeader
    )
    .spread (response, body) ->
      res = JSON.parse(body)
      return _.filter(
        res.unreadcounts
        (feed) -> _.str.startsWith(feed.id, 'feed/')
      )

  fetchUnreadEntries: (feedId, items, continuation) ->
    request.getAsync(
      url: 'https://cloud.feedly.com/v3/streams/contents'
      headers: authHeader
      qs:
        streamId: feedId
        unreadOnly: true
        continuation: continuation
    )
    .spread (response, body) =>
      res = JSON.parse(body)
      items = if items? then items.concat(res.items) else res.items

      if res.continuation?
        @fetchUnreadEntries(feedId, items, res.continuation)
      else
        return _.map(
          items
          (item) -> new Entry(
            res.title
            item.id
            item.categories?[0]?.label
            item.title
            item.alternate[0].href
          )
        )

  markAsRead: (entryIds) ->
    request.postAsync(
      url: 'https://cloud.feedly.com/v3/markers'
      headers: authHeader
      json:
        action: "markAsRead"
        entryIds: entryIds
        type: "entries"
    )

class Entry
  constructor: (@sourceName, @id, @category, @title, @url) ->
    return

  splitSourceName: () ->
    s = @sourceName
    s = s.replace(/^All News on  'The Twitter Times: .*$/, "t") # 文字数節約
    s = s.replace(/^はてなブックマーク - .*$/, "h") # 文字数節約
    s = s.replace(".", ",") # 自動リンク避け
    return s

  escapeTitle: () ->
    t = @title
    t = t.replace("@", "!") # 誤メンション避け
    t = t.replace("#", "?") # ハッシュタグ避け
    t = t.replace(".", ",") # 自動リンク避け

  breakText: (text) ->
    TEXT_LIMIT = 116 # 23 chars are reserved for url

    if text.length > TEXT_LIMIT
      over = text.length - TEXT_LIMIT
      return _.str.prune(text, over, "…")
    else
      return text

  shortenUrl: () ->
    request.getAsync(
      url: 'https://api-ssl.bitly.com/v3/shorten'
      qs:
        access_token: process.env.BITLY_ACCESS_TOKEN
        longUrl: @url
    )
    .spread (response, body) ->
      res = JSON.parse(body)
      return res.data.url

  makeFeedText: () ->
    return "#{@sourceName} #{@title} #{@url}"

processTask = (robot, envelope) ->
  f = new Feedly

  async () ->
    feeds = await f.fetchFeeds()

    unreadFeedIds =
      _.chain(feeds)
        .filter((f) -> f.count isnt 0)
        .map((f) -> f.id)
        .value()

    unreadEntries =
      await _.map(unreadFeedIds, (id) -> f.fetchUnreadEntries id)

    # 既読にしたくないエントリーを除外
    markAsReadEntries =
      _.chain(unreadEntries)
        .flatten()
        .reject((entry) -> _.str.endsWith(entry.category, '-no-bot'))
        .value()

    # メッセージを送信したくないエントリーを除外
    # 重複メッセージを避けるため既読にしないエントリーはメッセージも送信しない
    sendEntries =
      _.reject(
        markAsReadEntries
        (entry) -> _.str.include(entry.url, '//twitter.com/')
      )

    messages =
      await _.map(sendEntries, (e) -> e.makeFeedText())

    await _.map(messages, (m)-> robot.send(envelope, m))
    #await f.markAsRead _.map(markAsReadEntries, (e)-> (e.id))
  .call()

module.exports = (robot) ->
  new cronJob('*/2 * * * *', () ->
    processTask(robot, { room: process.env.HUBOT_ROOM_NAME })
  )
  .start()

  robot.respond /feed$/i, (msg) ->
    processTask(robot, { room: msg.envelope.room })
