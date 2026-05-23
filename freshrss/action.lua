local M = {}
local CACHE_NAMESPACE = 'freshrss'

local runtime = {
  cfg = nil,
  state = nil,
  greader = nil,
  cache_key = nil,
}

local function trim(s)
  if not s then return nil end
  return tostring(s):match '^%s*(.-)%s*$'
end

local function decode_html_entities(text)
  if not text then return '' end
  local entities = {
    ['&nbsp;'] = ' ',
    ['&amp;'] = '&',
    ['&lt;'] = '<',
    ['&gt;'] = '>',
    ['&quot;'] = '"',
    ['&#39;'] = "'",
  }
  text = text:gsub('&#x([%da-fA-F]+);', function(hex)
    local code = tonumber(hex, 16)
    return code and utf8.char(code) or ''
  end)
  text = text:gsub('&#(%d+);', function(dec)
    local code = tonumber(dec)
    return code and utf8.char(code) or ''
  end)
  for entity, replacement in pairs(entities) do
    text = text:gsub(entity, replacement)
  end
  return text
end

local function html_to_text(html)
  if not html or html == '' then return '' end
  local text = tostring(html)
  text = text:gsub('<[bB][rR]%s*/?>', '\n')
  text = text:gsub('</[pP]>', '\n\n')
  text = text:gsub('</[hH][1-6]>', '\n\n')
  text = text:gsub('</[lL][iI]>', '\n')
  text = text:gsub('<[lL][iI][^>]*>', '• ')
  text = text:gsub('</[uU][lL]>', '\n')
  text = text:gsub('</[oO][lL]>', '\n')
  text = text:gsub('</[dD][iI][vV]>', '\n')
  text = text:gsub('</[tT][rR]>', '\n')
  text = text:gsub('</[tT][dD]>', ' ')
  text = text:gsub('<script[%s%S]-</script>', '')
  text = text:gsub('<style[%s%S]-</style>', '')
  text = text:gsub('<[^>]+>', '')
  text = decode_html_entities(text)
  text = text:gsub('\r\n', '\n')
  text = text:gsub('\r', '\n')
  text = text:gsub('[ \t]+\n', '\n')
  text = text:gsub('\n[ \t]+', '\n')
  text = text:gsub('\n\n\n+', '\n\n')
  text = text:gsub('[ \t][ \t]+', ' ')
  return text:trim()
end

local function path_key(path) return table.concat(path or {}, '\1') end

local function clone_item(item)
  local copied = {}
  for k, v in pairs(item or {}) do
    copied[k] = v
  end
  return copied
end

local function clone_entry(entry)
  local copied = {}
  for k, v in pairs(entry or {}) do
    if k == 'item' and type(v) == 'table' then
      copied[k] = clone_item(v)
    else
      copied[k] = v
    end
  end
  return setmetatable(copied, getmetatable(entry))
end

local function cache_key(name) return runtime.cache_key(name) end

local function current_path_entries()
  return runtime.state.page_entries[path_key(deck.api.get_current_path())]
end

local function entry_index_by_key(entries, key)
  for i, entry in ipairs(entries or {}) do
    if entry.kind == 'item' and tostring(entry.key) == tostring(key) then return i end
  end
end

local function feed_for_entry(entry)
  if not entry or entry.kind ~= 'item' then return nil end
  local feeds = deck.cache.get(CACHE_NAMESPACE, cache_key 'feeds')
  return feeds and feeds.by_id and feeds.by_id[tostring(entry.item.feed_id)] or nil
end

local function section_preview(title, description, extra)
  local lines = {
    deck.style.line { deck.style.span(title):fg 'yellow' },
    '',
    description,
  }
  if extra and extra ~= '' then
    table.insert(lines, '')
    table.insert(lines, extra)
  end
  return deck.style.text(lines)
end

local function article_preview(entry, feed)
  local item = entry.item
  local text = html_to_text(item.html)
  local lines = {
    deck.style.line { deck.style.span(item.title or '(no title)'):fg 'yellow' },
    deck.style.line {
      deck.style.span((feed and feed.title) or ('Feed ' .. tostring(item.feed_id))):fg 'blue',
      deck.style.span('  '):fg 'white',
      deck.style.span(item.created_on_time and deck.time.format(item.created_on_time) or ''):fg 'darkgray',
    },
  }

  if item.author and item.author ~= '' then
    table.insert(lines, deck.style.line {
      deck.style.span('Author: '):fg 'cyan',
      deck.style.span(item.author):fg 'white',
    })
  end

  table.insert(lines, deck.style.line {
    deck.style.span('Status: '):fg 'cyan',
    deck.style.span(item.is_read and 'read' or 'unread'):fg(item.is_read and 'darkgray' or 'green'),
    deck.style.span('  saved: '):fg 'cyan',
    deck.style.span(item.is_saved and 'yes' or 'no'):fg(item.is_saved and 'yellow' or 'darkgray'),
  })

  if item.url and item.url ~= '' then
    table.insert(lines, deck.style.line {
      deck.style.span('URL: '):fg 'cyan',
      deck.style.span(item.url):fg 'magenta',
    })
  end

  table.insert(lines, '')
  table.insert(lines, text ~= '' and text or '(empty content)')
  table.insert(lines, '')
  table.insert(lines, 'Enter/o 打开原文  r 标记已读  s 收藏/取消收藏  y 复制链接')
  return deck.style.text(lines)
end

local function render_current_page(entries)
  deck.api.set_entries(nil, entries)
  local hovered = deck.api.get_hovered()
  if not hovered then return end

  if hovered.kind == 'item' then
    local idx = entry_index_by_key(entries, hovered.key)
    if idx then deck.api.set_preview(nil, article_preview(entries[idx], feed_for_entry(entries[idx]))) end
    return
  end

  if hovered.kind == 'section' then
    if hovered.key == 'all' then
      deck.api.set_preview(nil, section_preview(hovered.title or 'All', hovered.preview_desc or 'Browse all feeds.'))
      return
    end
    if hovered.key == 'unread' then
      deck.api.set_preview(nil, section_preview(hovered.title or 'Unread', hovered.preview_desc or 'Browse unread feeds and articles.'))
      return
    end
    if hovered.key == 'saved' then
      deck.api.set_preview(nil, section_preview(hovered.title or 'Saved', hovered.preview_desc or 'Browse saved articles.'))
      return
    end
  end

  if hovered.kind == 'feed' and hovered.feed then
    local feed = hovered.feed
    deck.api.set_preview(nil, section_preview(
      feed.title or ('Feed ' .. hovered.key),
      feed.site_url or feed.url or '',
      'Enter 查看该订阅源文章  o 打开站点'
    ))
    return
  end

  if hovered.kind == 'info' then
    deck.api.set_preview(nil, M.info_preview(hovered))
  end
end

local function refresh_entry_display(entry)
  if not entry or entry.kind ~= 'item' then return end
  local feed = feed_for_entry(entry)
  local feed_title = feed and feed.title or ('Feed ' .. tostring(entry.item.feed_id))
  entry.display = M.item_display(entry.item, feed_title)
end

local function update_entry_locally(id, mutator)
  local entries = current_path_entries()
  if not entries then return nil end

  local idx = entry_index_by_key(entries, id)
  if not idx then return nil end

  local previous = clone_entry(entries[idx])
  mutator(entries[idx])
  refresh_entry_display(entries[idx])
  render_current_page(entries)
  return previous
end

function M.setup(opts)
  runtime.cfg = opts.cfg
  runtime.state = opts.state
  runtime.greader = opts.greader
  runtime.cache_key = opts.cache_key
end

function M.show_error(err)
  deck.notify(deck.style.line {
    deck.style.span('✗ '):fg 'red',
    deck.style.span(tostring(err)):fg 'red',
  })
end

function M.remember_entries(path, entries)
  runtime.state.page_entries[path_key(path)] = entries
end

function M.invalidate_cache()
  runtime.state.cache_version = runtime.state.cache_version + 1
end

function M.item_display(item, feed_title)
  local read_icon = item.is_read and '󰇯' or '󰇮'
  local read_color = item.is_read and 'darkgray' or 'cyan'
  local title = trim(item.title)
  if not title or title == '' then title = '(no title)' end
  local date = item.created_on_time and deck.time.format(item.created_on_time, 'compact') or ''

  return deck.style.line {
    deck.style.span(read_icon .. ' '):fg(read_color),
    deck.style.span(title):fg(item.is_read and 'darkgray' or 'white'),
    deck.style.span('  ' .. (feed_title or '')):fg 'blue',
    deck.style.span('  ' .. date):fg 'darkgray',
  }
end

function M.to_item_entry(item, feeds)
  local feed = feeds and feeds.by_id and feeds.by_id[tostring(item.feed_id)] or nil
  local feed_title = feed and feed.title or ('Feed ' .. tostring(item.feed_id))
  local key = item.api_id or tostring(item.id)
  return {
    key = key,
    kind = 'item',
    id = item.id,
    api_id = item.api_id,
    item = item,
    url = item.url,
    display = M.item_display(item, feed_title),
  }
end

function M.open_entry(entry)
  if not entry then return end

  if entry.kind == 'item' and entry.url and entry.url ~= '' then
    deck.system.open(entry.url)
    return
  end

  if entry.kind == 'feed' and entry.url and entry.url ~= '' then deck.system.open(entry.url) end
end

function M.unsubscribe_feed(entry)
  entry = entry or deck.api.get_hovered()
  if not entry or entry.kind ~= 'feed' or not entry.feed then return end

  local feed = entry.feed
  local title = feed.title or ('Feed ' .. tostring(feed.id or entry.key))
  deck.confirm({
    title = 'Unsubscribe Feed',
    prompt = 'Unsubscribe "' .. title .. '"?',
    on_confirm = function()
      runtime.greader.unsubscribe_feed(feed.id or entry.key, function(_, err)
        if err then
          M.show_error(err)
          return
        end

        M.invalidate_cache()
        runtime.state.page_entries = {}
        deck.notify(deck.style.line {
          deck.style.span('✓ '):fg 'green',
          deck.style.span('Unsubscribed ' .. title):fg 'green',
        })
        deck.cmd 'reload'
      end)
    end,
  })
end

function M.copy_url(entry)
  entry = entry or deck.api.get_hovered()
  if not entry or not entry.url or entry.url == '' then return end
  deck.osc52_copy(entry.url)
  deck.notify 'Article URL copied'
end

function M.set_mark(entry, mark)
  entry = entry or deck.api.get_hovered()
  if not entry or entry.kind ~= 'item' then return end

  local previous
  if mark == 'read' then
    previous = update_entry_locally(entry.key, function(local_entry) local_entry.item.is_read = true end)
  elseif mark == 'saved' or mark == 'unsaved' then
    previous = update_entry_locally(entry.key, function(local_entry) local_entry.item.is_saved = mark == 'saved' end)
  end

  local adds = {}
  local removes = {}
  if mark == 'read' then
    adds = { 'user/-/state/com.google/read' }
  elseif mark == 'saved' then
    adds = { 'user/-/state/com.google/starred' }
  elseif mark == 'unsaved' then
    removes = { 'user/-/state/com.google/starred' }
  end

  runtime.greader.edit_tag({ entry.item.api_id }, adds, removes, function(_, err)
    if err then
      if previous then
        update_entry_locally(entry.key, function(local_entry)
          local_entry.item = previous.item
          local_entry.url = previous.url
        end)
      end
      M.show_error(err)
      return
    end
    M.invalidate_cache()
    deck.notify(deck.style.line {
      deck.style.span('✓ '):fg 'green',
      deck.style.span('Updated article state'):fg 'green',
    })
  end)
end

function M.mark_read(entry)
  entry = entry or deck.api.get_hovered()
  if entry and entry.kind == 'item' and not entry.item.is_read then M.set_mark(entry, 'read') end
end

function M.toggle_saved(entry)
  entry = entry or deck.api.get_hovered()
  if not entry or entry.kind ~= 'item' then return end
  M.set_mark(entry, entry.item.is_saved and 'unsaved' or 'saved')
end

function M.section_preview(entry)
  if entry.title then
    return section_preview(entry.title, entry.preview_desc or '')
  end
  return section_preview('FreshRSS', 'Use Enter to browse sections.')
end

function M.feed_preview(entry)
  local feed = entry.feed or {}
  local desc = feed.site_url or feed.url or ''
  if entry.unread_count ~= nil then
    desc = desc ~= '' and (desc .. '\nUnread: ' .. tostring(entry.unread_count)) or ('Unread: ' .. tostring(entry.unread_count))
  end
  return section_preview(
    feed.title or ('Feed ' .. tostring(entry.key)),
    desc,
    'Enter 查看该订阅源文章  o 打开站点'
  )
end

function M.item_preview(entry, cb)
  runtime.greader.fetch_feeds(function(feeds, err)
    if err then
      cb(section_preview('FreshRSS', 'Failed to load feed metadata', tostring(err)))
      return
    end
    local feed = feeds and feeds.by_id and feeds.by_id[tostring(entry.item.feed_id)] or nil
    cb(article_preview(entry, feed))
  end)
end

function M.info_preview(entry)
  return section_preview(entry.title or 'FreshRSS', entry.message or '', entry.detail or '')
end

function M.missing_config_preview()
  return section_preview(
    'FreshRSS',
    '请在 setup() 中设置 url/login/password，或导出 FRESHRSS_URL/FRESHRSS_LOGIN/FRESHRSS_PASSWORD。'
  )
end

return M
