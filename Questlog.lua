--[[
  QuestLog-UnrealUI.lua —— 单文件版（原生材质版）
  从 UnrealUI-E 真实源码提取，合并框架垫片 + questlog.lua 逻辑

  这一版去掉了自绘皮肤系统（剥原生贴图 + 重绘背景/边框/按钮/滚动条/折叠图标），
  改用暴雪原生贴图和默认外观。保留的是功能性代码：
    - 窗口拖动
    - 窗口/列表/详情区域的尺寸与布局
    - 任务行数据（等级拼接显示 + 按难度着色）
    - 原生事件钩子（QuestLog_OnShow / QuestLog_Update 刷新联动）

  已确认删除、且不影响功能的部分：
    - 折叠图标系统（连带点击折叠/展开任务标题的功能）
    - 展开/收起详情面板的自绘箭头按钮（详情面板现在固定显示）
    - 任务等级显示开关（该配置项已不存在，等级信息始终显示）
    - 任务追踪记忆恢复、追踪标记、可拖动的任务追踪面板
    - 主题开关判断（ThemeStyleUsesNativeChrome，之前恒定返回false，等于没用）

  单文件独立运行，不再共享全局 UnrealUI 表——所有工具函数都是本文件内的
  局部函数（local function），不对外暴露、不污染全局命名空间。
--]]

-- ============================================================
-- 全局变量读写
-- ============================================================

local _getglobal = getglobal
if not _getglobal then
  _getglobal = function(name) if _G then return _G[name] end return nil end
end

local function G(name)
  if type(name) ~= "string" then return nil end
  local ok, value = pcall(_getglobal, name)
  if ok then return value end
  return nil
end

local _setglobal = setglobal
if not _setglobal then
  _setglobal = function(name, value) if _G then _G[name] = value end end
end

local function SetG(name, value)
  if type(name) ~= "string" then return false end
  return pcall(_setglobal, name, value)
end

-- ============================================================
-- 输出/调试
-- ============================================================

local function Output(text)
  local chatFrame = G("DEFAULT_CHAT_FRAME")
  if chatFrame and chatFrame.AddMessage then pcall(chatFrame.AddMessage, chatFrame, text) end
end

local function Error(msg) Output("|cfff5ae0aQuestLog|r |cffff5555error|r: " .. tostring(msg)) end
local function Debug(msg) Output("|cfff5ae0aQuestLog|r |cff888888debug|r: " .. tostring(msg)) end

-- ============================================================
-- Post-hook（叠加全局函数，不覆盖原逻辑）
-- ============================================================

local hookedGlobals = {}

local function PostHookGlobal(name, callback)
  if type(name) ~= "string" or type(callback) ~= "function" then return false end
  local callbacks = hookedGlobals[name]
  if not callbacks then
    local original = G(name)
    if type(original) ~= "function" then return false end
    callbacks = {}
    local wrapper = function(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
      local r1, r2, r3, r4, r5 = original(a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
      local i
      for i = 1, table.getn(callbacks) do
        local ok, err = pcall(callbacks[i], a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
        if not ok then Error(name .. " hook: " .. tostring(err)) end
      end
      return r1, r2, r3, r4, r5
    end
    SetG(name, wrapper)
    if G(name) ~= wrapper then return false end
    hookedGlobals[name] = callbacks
  end
  table.insert(callbacks, callback)
  return true
end

-- ============================================================
-- 区域隐藏（仅用于隐藏原生"监视任务"复选框）
-- ============================================================

local function HideRegion(region)
  if not region then return false end
  pcall(function() if region.SetTexture then region:SetTexture(nil) end end)
  pcall(function() if region.SetAlpha then region:SetAlpha(0) end end)
  pcall(function() if region.Hide then region:Hide() end end)
  return true
end

-- ============================================================
-- 拖拽（简化版，无碰撞避让）
-- ============================================================

local function MakeWindowDraggable(id, frame)
  if not frame then return end
  frame:SetMovable(true)
  pcall(frame.EnableMouse, frame, true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function() frame:StartMoving() end)
  frame:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
end

--[[============================================================
  以下是 questlog.lua 原始逻辑，除末尾入口调用方式外未作改动
================================================================]]

local QUEST_ROWS = 23

local frame, detail, listScroll

local function IsShown(object)
  if not object or not object.IsShown then return false end
  local ok, shown = pcall(object.IsShown, object)
  return ok and shown and true or false
end

local function BuildRows()
  local first = G("QuestLogTitle1")
  if not first or not listScroll then return end
  pcall(function() first:ClearAllPoints() first:SetPoint("TOPLEFT", listScroll, "TOPLEFT", 0, 0) end)

  local i
  for i = 7, QUEST_ROWS do
    local name = "QuestLogTitle" .. i
    local row = G(name)
    if not row then
      local ok, created = pcall(CreateFrame, "Button", name, frame, "QuestLogTitleButtonTemplate")
      if ok then row = created end
    end
    local previous = G("QuestLogTitle" .. (i - 1))
    if row and previous then
      pcall(row.SetID, row, i)
      pcall(function() row:ClearAllPoints() row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, 1) end)
    end
  end

end

local function UpdateRows()
  local getCount = G("GetNumQuestLogEntries")
  local getTitle = G("GetQuestLogTitle")
  local getColor = G("GetQuestDifficultyColor")
  local offsetFn = G("FauxScrollFrame_GetOffset")
  if type(getCount) ~= "function" or type(getTitle) ~= "function" then return end

  local ok, numEntries = pcall(getCount)
  if not ok or not tonumber(numEntries) then return end

  local offset = 0
  if type(offsetFn) == "function" and listScroll then
    local offsetOk, value = pcall(offsetFn, listScroll)
    if offsetOk and tonumber(value) then offset = value end
  end

  local i

  for i = 1, QUEST_ROWS do
    local row = G("QuestLogTitle" .. i)
    local check = G("QuestLogTitle" .. i .. "Check")
    if check then HideRegion(check) end

    local questIndex = i + offset
    local titleOk, text, level, questTag, isHeader, isCollapsed
    if row and questIndex <= numEntries then
      titleOk, text, level, questTag, isHeader, isCollapsed = pcall(getTitle, questIndex)
      titleOk = titleOk and type(text) == "string"
    end

    if row and titleOk and not isHeader then
      local shownLevel = tostring(level or "?") .. (questTag and "+" or "")
      pcall(row.SetText, row, " [" .. shownLevel .. "] " .. text)
      if type(getColor) == "function" and tonumber(level) then
        local colorOk, r, g, b = pcall(getColor, level)
        if colorOk and r then pcall(row.SetTextColor, row, r, g, b) end
      end
    end
  end
end

local function StyleQuestItems()
  local maxItems = tonumber(G("MAX_NUM_ITEMS")) or 10
  local i
  for i = 1, maxItems do
    local name = "QuestLogItem" .. i
    local item = G(name)
    local icon = G(name .. "IconTexture")
    if item and not item.uuiQuestItemStyled then
      item.uuiQuestItemStyled = true
      local widthOk, width = pcall(item.GetWidth, item)
      if widthOk and tonumber(width) and width > 12 then pcall(item.SetWidth, item, width - 12) end
      if icon then
        local heightOk, height = pcall(item.GetHeight, item)
        local iconSize = heightOk and tonumber(height) and math.max(height - 12, 16) or 32
        pcall(function()
          icon:ClearAllPoints() icon:SetWidth(iconSize) icon:SetHeight(iconSize)
          icon:SetPoint("LEFT", item, "LEFT", 6, 0)
          icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
          icon:Show() icon:SetAlpha(1)
        end)
      end
      local title = G(name .. "Name")
      if title and icon then
        pcall(function()
          title:ClearAllPoints()
          title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 5, 0)
          title:SetPoint("BOTTOMRIGHT", item, "BOTTOMRIGHT", -5, 4)
          title:SetJustifyH("LEFT") title:SetJustifyV("MIDDLE")
        end)
      end
      local count = G(name .. "Count")
      if count and icon then
        pcall(function() count:ClearAllPoints() count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1) end)
      end
    end
  end
end

local function BuildFrame()
  frame = G("QuestLogFrame")
  detail = G("QuestLogDetailScrollFrame")
  listScroll = G("QuestLogListScrollFrame")
  if not frame or not detail or not listScroll then
    Debug("questlog: native frame unavailable")
    return false
  end

  QUESTS_DISPLAYED = QUEST_ROWS
  MAX_WATCHABLE_QUESTS = 20

  pcall(frame.SetWidth, frame, 676)
  pcall(frame.SetHeight, frame, 440)

  local title = G("QuestLogTitleText")
  if title then pcall(function() title:ClearAllPoints() title:SetPoint("TOP", frame, "TOP", 0, -10) end) end
  MakeWindowDraggable("questlog", frame)

  local count = G("QuestLogQuestCount")
  if count then pcall(function() count:ClearAllPoints() count:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -10, -30) end) end

  local emptyText = G("QuestLogNoQuestsText")
  if emptyText then pcall(function() emptyText:ClearAllPoints() emptyText:SetPoint("TOP", frame, "TOP", 0, -100) end) end

  local abandon = G("QuestLogFrameAbandonButton")
  local push = G("QuestFramePushQuestButton")
  local exit = G("QuestFrameExitButton")
  if abandon then pcall(function() abandon:ClearAllPoints() abandon:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 5, 5) abandon:SetWidth(98) end) end
  if push and abandon then pcall(function() push:ClearAllPoints() push:SetPoint("LEFT", abandon, "RIGHT", 5, 0) push:SetWidth(98) end) end
  if exit and push then pcall(function() exit:ClearAllPoints() exit:SetPoint("LEFT", push, "RIGHT", 5, 0) exit:SetWidth(99) end) end

  local collapseAll = G("QuestLogCollapseAllButton")
  if collapseAll and G("QuestLogTitle1") then
    pcall(function() collapseAll:ClearAllPoints() collapseAll:SetPoint("BOTTOMLEFT", G("QuestLogTitle1"), "TOPLEFT", -6, 4) end)
  end

  pcall(function() listScroll:ClearAllPoints() listScroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -54) listScroll:SetHeight(350) end)

  pcall(function() detail:ClearAllPoints() detail:SetPoint("TOPLEFT", listScroll, "TOPRIGHT", 35, 0) detail:SetHeight(376) end)
  local detailChild = G("QuestLogDetailScrollChildFrame")
  if detailChild then pcall(detailChild.SetHeight, detailChild, 376) end

  BuildRows()
  StyleQuestItems()

  PostHookGlobal("QuestLog_OnShow", function()
    pcall(function() frame:ClearAllPoints() frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 10, -104) end)
  end)
  PostHookGlobal("QuestLog_Update", function() UpdateRows() end)

  if IsShown(frame) then UpdateRows() end
  return true
end

-- ============================================================
-- 入口（不走完整模块生命周期，直接调用）
-- ============================================================

local bootstrap = CreateFrame("Frame")
bootstrap:RegisterEvent("PLAYER_ENTERING_WORLD")
bootstrap:SetScript("OnEvent", function()
  pcall(function() bootstrap:UnregisterEvent("PLAYER_ENTERING_WORLD") end)
  pcall(BuildFrame)
end)