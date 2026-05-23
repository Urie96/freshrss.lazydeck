local action = require 'freshrss.action'
local config = require 'freshrss.config'
local GReader = require 'freshrss.greader'
local meta = require 'freshrss.meta'

local M = {}

function M.meta()
  return {
    icon = '',
    desc = 'FreshRSS feed reader',
    color = 'yellow',
  }
end

local state = {
  auth = nil,
  edit_token = nil,
  cache_version = 0,
  page_entries = {},
}

local CACHE_PREFIX = 'freshrss:'
local greader

local function cache_key(name) return CACHE_PREFIX .. state.cache_version .. ':' .. name end

local function section_entry(key, icon, icon_color, title, count, opts)
  opts = opts or {}
  return {
    key = key,
    kind = 'section',
    title = opts.preview_title or title,
    preview_desc = opts.preview_desc or '',
    display = deck.style.line {
      deck.style.span(icon .. ' '):fg(icon_color),
      deck.style.span(title):fg 'white',
      deck.style.span('  ' .. tostring(count or 0)):fg 'darkgray',
    },
  }
end

local function feed_entry(feed, opts)
  opts = opts or {}
  local updated = feed.last_updated_on_time and deck.time.format(feed.last_updated_on_time, 'compact') or ''
  local unread_count = opts.unread_count
  return {
    key = tostring(feed.id),
    kind = 'feed',
    feed = feed,
    url = feed.site_url or feed.url,
    unread_count = unread_count,
    display = deck.style.line {
      deck.style.span(feed.title or ('Feed ' .. tostring(feed.id))):fg 'white',
      deck.style.span(feed.group_title and ('  [' .. feed.group_title .. ']') or ''):fg 'blue',
      deck.style.span(unread_count ~= nil and ('  unread: ' .. tostring(unread_count)) or ''):fg 'cyan',
      deck.style.span(updated ~= '' and ('  ' .. updated) or ''):fg 'darkgray',
    },
  }
end

local function remember(path, entries)
  action.remember_entries(path, entries)
  return entries
end

local function list_root(path, cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    greader.fetch_stream_item_count('user/-/state/com.google/starred', nil, function(saved_count, saved_err)
      if saved_err then
        cb(nil, saved_err)
        return
      end

      local unread_feed_count = 0
      for _, feed in ipairs(feeds.feeds or {}) do
        if (feed.unread_count or 0) > 0 then unread_feed_count = unread_feed_count + 1 end
      end

      cb(remember(path, meta.attach {
        section_entry('all', '', 'green', 'All', #(feeds.feeds or {}), {
          preview_title = 'All feeds',
          preview_desc = 'Browse all feeds and then open a feed to read its articles.',
        }),
        section_entry('unread', '', 'cyan', 'Unread', unread_feed_count, {
          preview_title = 'Unread',
          preview_desc = 'Browse feeds with unread items, or open all unread articles.',
        }),
        section_entry('saved', '', 'yellow', 'Saved', saved_count or 0, {
          preview_title = 'Saved',
          preview_desc = 'Browse saved articles.',
        }),
      }))
    end)
  end)
end

local function list_all_feeds(path, cb)
  greader.fetch_feeds(function(feeds, err)
    if err then
      cb(nil, err)
      return
    end

    local entries = {}
    for _, feed in ipairs(feeds.feeds or {}) do
      table.insert(entries, feed_entry(feed, { unread_count = nil }))
    end

    cb(remember(path, meta.attach(entries)))
  end)
end

local function list_unread_feeds(path, cb)
  greader.fetch_feeds(function(feeds, err)
    if err then
      cb(nil, err)
      return
    end

    local entries = {
      section_entry('all', '', 'cyan', 'All unread', feeds.unread_total or 0, {
        preview_title = 'All unread',
        preview_desc = 'Browse unread articles from every subscription.',
      }),
    }

    for _, feed in ipairs(feeds.feeds or {}) do
      if (feed.unread_count or 0) > 0 then
        table.insert(entries, feed_entry(feed, { unread_count = feed.unread_count }))
      end
    end

    cb(remember(path, meta.attach(entries)))
  end)
end

local function list_virtual_items(path, kind, cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    local stream_path
    local params = {}
    if kind == 'unread' then
      stream_path = '/stream/contents/reading-list'
      params.xt = 'user/-/state/com.google/read'
    elseif kind == 'saved' then
      stream_path = '/stream/contents/user/-/state/com.google/starred'
    else
      cb(nil, 'unsupported virtual stream')
      return
    end

    greader.fetch_stream_items(kind .. '_items', stream_path, params, config.get().feed_fetch_max_pages, function(items, items_err)
      if items_err then
        cb(nil, items_err)
        return
      end

      local entries = {}
      for _, item in ipairs(items or {}) do
        table.insert(entries, action.to_item_entry(item, feeds))
      end

      cb(remember(path, meta.attach(entries)))
    end)
  end)
end

local function list_feed_articles(path, feed_id, params, cb)
  greader.fetch_feeds(function(feeds, feed_err)
    if feed_err then
      cb(nil, feed_err)
      return
    end

    greader.fetch_feed_items(feed_id, params, function(items, items_err)
      if items_err then
        cb(nil, items_err)
        return
      end

      local entries = {}
      for _, item in ipairs(items or {}) do
        table.insert(entries, action.to_item_entry(item, feeds))
      end

      cb(remember(path, meta.attach(entries)))
    end)
  end)
end

function M.setup(opt)
  config.setup(opt or {})

  state.auth = nil
  state.edit_token = nil
  state.cache_version = 0
  state.page_entries = {}

  greader = GReader.create {
    cfg = config.get(),
    state = state,
    cache_key = cache_key,
  }

  action.setup {
    cfg = config.get(),
    state = state,
    greader = greader,
    cache_key = cache_key,
  }
  meta.setup(config.get())
end

function M.list(path, cb)
  if not config.ready() then
    cb(meta.attach {
      {
        key = 'configure',
        kind = 'info',
        title = 'FreshRSS',
        message = 'Configure FreshRSS in setup() or env vars',
        detail = 'Set url/login/password or export FRESHRSS_URL/FRESHRSS_LOGIN/FRESHRSS_PASSWORD.',
        color = 'yellow',
      },
    })
    return
  end

  if #path == 1 then
    list_root(path, function(entries, err)
      if err then
        action.show_error(err)
        cb(meta.attach {})
        return
      end
      cb(entries)
    end)
    return
  end

  if path[2] == 'all' or path[2] == 'feeds' then
    if #path == 2 then
      list_all_feeds(path, function(entries, err)
        if err then
          action.show_error(err)
          cb(meta.attach {})
          return
        end
        cb(entries)
      end)
      return
    end

    if #path == 3 then
      list_feed_articles(path, path[3], nil, function(entries, err)
        if err then
          action.show_error(err)
          cb(meta.attach {})
          return
        end
        cb(entries)
      end)
      return
    end
  end

  if path[2] == 'unread' then
    if #path == 2 then
      list_unread_feeds(path, function(entries, err)
        if err then
          action.show_error(err)
          cb(meta.attach {})
          return
        end
        cb(entries)
      end)
      return
    end

    if #path == 3 and path[3] == 'all' then
      list_virtual_items(path, 'unread', function(entries, err)
        if err then
          action.show_error(err)
          cb(meta.attach {})
          return
        end
        cb(entries)
      end)
      return
    end

    if #path == 3 then
      list_feed_articles(path, path[3], { xt = 'user/-/state/com.google/read' }, function(entries, err)
        if err then
          action.show_error(err)
          cb(meta.attach {})
          return
        end
        cb(entries)
      end)
      return
    end
  end

  if path[2] == 'saved' then
    if #path == 2 then
      list_virtual_items(path, 'saved', function(entries, err)
        if err then
          action.show_error(err)
          cb(meta.attach {})
          return
        end
        cb(entries)
      end)
      return
    end
  end

  cb(meta.attach {})
end

return M
