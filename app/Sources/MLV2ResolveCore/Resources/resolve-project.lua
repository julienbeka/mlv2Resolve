-- SPDX-License-Identifier: GPL-3.0-or-later
-- SHOOTS, APPROVED, MENU and localized TEXT are supplied by ResolveProject.swift.
do
local function shell(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function apple(s) return '"' .. s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '') .. '"' end
local function dialog(message, confirm)
  local source = 'display dialog ' .. apple(message) .. ' with title "mlv2Resolve"'
  if confirm then source = source .. ' buttons {' .. apple(TEXT.cancel) .. ',' .. apple(TEXT.open) .. '} default button 1 cancel button 1'
  else source = source .. ' buttons {"OK"} default button 1' end
  local result = os.execute('/usr/bin/osascript -e ' .. shell(source) .. ' >/dev/null 2>&1')
  return result == true or result == 0
end
local function clean(s) return tostring(s):gsub('[\r\n]', ' ') end
local r = resolve
if not r then local ok,v = pcall(function() return Resolve() end); if ok then r=v end end
if not r then print('NO_RESOLVE'); return end
local pm = r:GetProjectManager()
if not pm then print('ERROR Project manager unavailable'); return end
local studio = (r:GetProductName() or ''):find('Studio', 1, true) ~= nil
local imported,already,failed,missing = 0,0,0,0
local details={}
local function warn(s) details[#details+1]=clean(s); print('WARNING ' .. clean(s)) end
local function property(item,key)
  local v=item:GetClipProperty(key)
  if type(v)=='table' then v=v[key] end
  return v and tostring(v) or ''
end
local function folderOf(path) return path:match('^(.*)/[^/]*$') end
local function visit(folder,seen)
  for _,item in ipairs(folder:GetClipList() or {}) do
    local path=property(item,'File Path')
    local directory=folderOf(path)
    if directory and path:lower():match('%.dng$') then seen[directory]=true end
  end
  for _,child in ipairs(folder:GetSubFolderList() or {}) do visit(child,seen) end
end
-- Resolve opens an unsaved startup project that SaveProject cannot name. Bypass it only when
-- it is still empty; names alone must never authorize discarding a user's project.
local function emptyStartupProject(project,name)
  local startupNames={['Untitled Project']=true,['Untitled']=true,['Sans titre']=true,['Projet sans titre']=true}
  if not startupNames[name] then return false end
  local checked,empty=pcall(function()
    local saved=pm:GetProjectListInCurrentFolder()
    if type(saved)~='table' then return false end
    for _,n in ipairs(saved) do if n==name then return false end end
    if project:GetTimelineCount()~=0 then return false end
    local root=project:GetMediaPool():GetRootFolder()
    local clips,folders=root:GetClipList(),root:GetSubFolderList()
    if type(clips)~='table' or type(folders)~='table' then return false end
    for _ in ipairs(clips) do return false end
    for _ in ipairs(folders) do return false end
    return true
  end)
  return checked and empty==true
end
local ok,err=pcall(function()
  for _,shoot in ipairs(SHOOTS) do
    if #shoot.clips==0 then
      for _,name in ipairs(shoot.warnings) do failed=failed+1; warn(shoot.name .. ': ' .. name) end
    else
    local current=pm:GetCurrentProject()
    local currentName=current and current:GetName() or nil
    if currentName and currentName~=shoot.name and not emptyStartupProject(current,currentName) then
      if MENU then
        if not dialog(TEXT.switch .. '\n' .. currentName .. ' → ' .. shoot.name, true) then print('CANCELLED'); return end
      elseif APPROVED~=currentName then
        print('SWITCH ' .. clean(currentName)); return
      end
      -- Preserve unsaved work before Resolve loads another project. A save refusal stops the switch.
      if not pm:SaveProject() then error('Could not save current project; switch cancelled') end
    end
    -- New app creations are anchored at the library root and never reuse a namesake.
    if CREATE_ONLY then
      if not pm:GotoRootFolder() then error('Could not open Resolve project root') end
      for _,name in ipairs(pm:GetProjectListInCurrentFolder() or {}) do
        if name==shoot.name then error('Project name already exists: ' .. shoot.name) end
      end
      currentName=nil
    end
    local project,created
    if currentName==shoot.name then project=current; created=false
    else
      local exists=false
      for _,name in ipairs(pm:GetProjectListInCurrentFolder() or {}) do if name==shoot.name then exists=true end end
      if exists then project=pm:LoadProject(shoot.name); created=false
      else project=pm:CreateProject(shoot.name); created=true end
    end
    if not project then error('Could not open project: ' .. shoot.name) end
    if created then
      if not studio and (shoot.width>3840 or shoot.height>2160) then shoot.width=3840; shoot.height=2160 end
      if not project:SetPreset('mlv2Resolve') and not project:SetPreset('mlv2dng') then missing=missing+1; warn(shoot.name .. ': preset mlv2Resolve missing') end
      local settings={
        {'colorScienceMode','davinciYRGB'}, {'separateColorSpaceAndGamma','1'},
        {'colorSpaceTimeline','DaVinci WG'}, {'colorSpaceTimelineGamma','DaVinci Intermediate'},
        {'colorSpaceOutput','Same as Timeline'},
        {'timelineFrameRate',tostring(shoot.fps)}, {'timelineInputResMismatchBehavior','scaleToFit'},
        {'timelineResolutionWidth',tostring(studio and shoot.width or math.min(shoot.width,3840))},
        {'timelineResolutionHeight',tostring(studio and shoot.height or math.min(shoot.height,2160))}}
      for _,setting in ipairs(settings) do
        if not project:SetSetting(setting[1],setting[2]) then error(shoot.name .. ': setting refused ' .. setting[1]) end
      end
    end
    local targetWidth,targetHeight=shoot.width,shoot.height
    do
      local got,w,h=pcall(function() return tonumber(project:GetSetting('timelineResolutionWidth')),tonumber(project:GetSetting('timelineResolutionHeight')) end)
      if got and w and h and w>0 and h>0 then targetWidth,targetHeight=w,h end
    end
    local pool=project:GetMediaPool()
    local root=pool:GetRootFolder()
    local seen={}; visit(root,seen)
    pool:SetCurrentFolder(root)
    local rushs=nil
    -- Existing projects receive media only. Never create or modify a timeline on a later run.
    if created then
      rushs=pool:ImportTimelineFromFile(TIMELINE_TEMPLATE,{timelineName=TIMELINE_NAME})
      if not rushs or not project:SetCurrentTimeline(rushs) then error('Could not import the timeline CST model. This Resolve version may not support it.') end
      if not rushs:SetName(TIMELINE_NAME) then error('Could not name timeline: ' .. TIMELINE_NAME) end
      local graph=rushs:GetNodeGraph()
      if not graph or graph:GetNumNodes()~=2 or not graph:SetNodeEnabled(1,true) or not graph:SetNodeEnabled(2,false) then
        error('Could not prepare timeline CST states; Rec.709 export node must remain disabled')
      end
      for _,setting in ipairs({{'useCustomSettings','1'},{'timelineFrameRate',tostring(shoot.fps)},
                                {'timelineResolutionWidth',tostring(targetWidth)},{'timelineResolutionHeight',tostring(targetHeight)},
                                {'timelineInputResMismatchBehavior','scaleToFit'}}) do
        if not rushs:SetSetting(setting[1],setting[2]) then error('Timeline setting refused: ' .. setting[1]) end
      end
    end
    for _,name in ipairs(shoot.warnings) do warn(shoot.name .. ': ' .. name) end
    for _,c in ipairs(shoot.clips) do
      if seen[c.dir] or seen[c.nfd] then already=already+1
      else
        local success,reason=pcall(function()
          local video=(pool:ImportMedia({{FilePath=c.path,StartIndex=c.first,EndIndex=c.last}}) or {})[1]
          if not video then error('DNG import refused') end
          seen[c.dir]=true; imported=imported+1
          if c.wav then
            local audio=(pool:ImportMedia({c.wav}) or {})[1]
            if not audio then warn(c.name .. ': WAV import refused')
            else
              local synced=pool:AutoSyncAudio({video,audio},{[r.AUDIO_SYNC_MODE]=r.AUDIO_SYNC_TIMECODE,[r.AUDIO_SYNC_RETAIN_VIDEO_METADATA]=true})
              if not synced then warn(c.name .. ': audio sync refused') end
            end
          else warn(c.name .. ': no WAV') end
          if c.factor>1 then
            local wanted='mlv2Resolve 1x' .. c.factor
            local fitZoom=1
            if studio then
              local rawFit=math.min(targetWidth/c.width,targetHeight/c.height)
              fitZoom=math.min(1,math.min(targetWidth/(c.width*c.factor),targetHeight/c.height)/rawFit)
              if fitZoom<=0.995 then
                wanted=string.format('mlv2Resolve 1x%d Fit %dx%d %dx%d',c.factor,targetWidth,targetHeight,c.width,c.height)
              end
            end
            local preset=property(video,'Input Sizing Preset')
            if preset=='' or preset=='None' then
              if not video:SetClipProperty('Input Sizing Preset',wanted) then warn(c.name .. ': sizing preset missing ' .. wanted .. string.format(' (Width=%.12g, Height=%.12g). Select it for this clip after saving the preset.',c.factor*fitZoom,fitZoom)) end
            elseif preset~=wanted then warn(c.name .. ': existing sizing preset kept') end
          end
          if rushs and INCLUDE_ALL_SHOTS then
            local timelineItems=pool:AppendToTimeline({video}) or {}
            if #timelineItems==0 then warn(c.name .. ': timeline append refused') end
            for _,item in ipairs(timelineItems) do
              local rawFit=math.min(targetWidth/c.width,targetHeight/c.height)
              local zoom=studio and 1 or math.min(1,math.min(targetWidth/(c.width*c.factor),targetHeight/c.height)/rawFit)
              if not item:SetProperty('ZoomX',zoom) or not item:SetProperty('ZoomY',zoom) then warn(c.name .. ': UHD zoom refused') end
            end
          end
        end)
        if not success then failed=failed+1; warn(c.name .. ': ' .. tostring(reason)) end
      end
    end
    if not pm:SaveProject() then error(shoot.name .. ': project save refused') end
    if CREATE_ONLY then
      local db=pm:GetCurrentDatabase()
      if type(db)=='table' and db.DbName then
        local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)) end
        local identity=(db.DbType or '') .. '|' .. (db.IpAddress or '') .. '|' .. db.DbName
        local receipt='LINK ' .. hex(shoot.source) .. ' ' .. hex(shoot.name) .. ' ' .. hex(identity)
        print(receipt)
        if RECEIPTS then
          local f=io.open(RECEIPTS,'a')
          if f then f:write(receipt .. '\n'); f:close() else warn('Could not remember linked project') end
        end
      else warn('Could not identify Resolve library; project link not cached') end
    end
    -- Consent for one source project is never reused for the next shoot.
    APPROVED=nil
    end
  end
  print(string.format('PROJECT imported=%d already=%d failed=%d missing=%d studio=%d',imported,already,failed,missing,studio and 1 or 0))
  if MENU then
    local message=TEXT.done .. '\n' .. string.format('DNG: %d / %d',imported,already)
    if #details>0 then message=message .. '\n' .. table.concat(details,'\n') end
    if missing>0 then message=message .. '\n\n' .. TEXT.guide end
    dialog(message,false)
  end
end)
if not ok then print('ERROR ' .. clean(err)); if MENU then dialog(tostring(err),false) end end
end
