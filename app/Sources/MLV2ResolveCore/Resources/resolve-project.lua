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
local cleanupPending=nil
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
      else
        if not pm:ImportProject(shoot.template,shoot.name) then error('Could not import bundled project model: ' .. shoot.name) end
        project=pm:LoadProject(shoot.name); created=true
      end
    end
    if not project then error('Could not open project: ' .. shoot.name) end
    if created then
      if not studio and (shoot.width>3840 or shoot.height>2160) then shoot.width=3840; shoot.height=2160 end
      -- Set the cadence before importing a model containing a clip: Resolve locks it afterwards.
      if not project:SetSetting('timelineFrameRate',tostring(shoot.fps)) then error('Project frame rate refused') end

    end
    local targetWidth,targetHeight=shoot.width,shoot.height
    if not created then
      local got,w,h=pcall(function() return tonumber(project:GetSetting('timelineResolutionWidth')),tonumber(project:GetSetting('timelineResolutionHeight')) end)
      if got and w and h and w>0 and h>0 then targetWidth,targetHeight=w,h end
    end
    local pool=project:GetMediaPool()
    local root=pool:GetRootFolder()
    local seen={}; visit(root,seen)
    pool:SetCurrentFolder(root)
    local rushs,gyroTemplate,gyroSource,gyroMedia,anchor=nil,nil,nil,nil,nil
    local modelFolderName='__mlv2Resolve_gyro_model'
    local function hasGyro(item)
      local graph=item:GetNodeGraph()
      if not graph then return false end
      for n=1,graph:GetNumNodes() do
        for _,tool in ipairs(graph:GetToolsInNode(n) or {}) do
          if tool:lower():find('gyroflow(niyien)',1,true) then return true end
        end
      end
      return false
    end
    -- Capture only the temporary objects created by this action. Also runs on setup errors.
    cleanupPending=function()
      if rushs then project:SetCurrentTimeline(rushs) end
      if anchor then
        if not pool:DeleteTimelines({anchor}) then warn('Could not remove temporary format anchor') end
        anchor=nil
      end
      if gyroTemplate then
        if not pool:DeleteTimelines({gyroTemplate}) then warn('Could not remove temporary Gyroflow model timeline') end
        gyroTemplate=nil
      end
      -- Resolve can ignore the requested bin. Remove the exact imported media object at root too.
      if gyroMedia then
        if not pool:DeleteClips({gyroMedia}) then warn('Could not remove temporary Gyroflow model media') end
        gyroMedia=nil
      end
      if created then
        for _,folder in ipairs(root:GetSubFolderList() or {}) do
          if folder:GetName()==modelFolderName then
            pool:SetCurrentFolder(root)
            if not pool:DeleteFolders({folder}) then warn('Could not remove temporary Gyroflow model bin') end
          end
        end
      end
    end
    -- Existing projects receive media only. Never create or modify a timeline on a later run.
    if created then
      -- An existing empty timeline anchors the chosen project cadence during DRT imports.
      anchor=pool:CreateEmptyTimeline('__mlv2Resolve_format_anchor')
      if not anchor then error('Could not initialize project format') end
      if INCLUDE_ALL_SHOTS then
        gyroTemplate=pool:ImportTimelineFromFile(GYRO_TEMPLATE,{importIntoSubFolderName=modelFolderName})
        if gyroTemplate then gyroSource=(gyroTemplate:GetItemListInTrack('video',1) or {})[1] end
        if gyroSource then gyroMedia=gyroSource:GetMediaPoolItem() end
        if not gyroSource or not hasGyro(gyroSource) then
          gyroSource=nil
          warn('Gyroflow(NiYien) plugin unavailable: install it before creating the project')
        end
      end
      rushs=pool:ImportTimelineFromFile(TIMELINE_TEMPLATE,{timelineName=TIMELINE_NAME})
      if not rushs or not project:SetCurrentTimeline(rushs) then error('Could not open the bundled project CST timeline. This Resolve version may not support it.') end
      if not pool:DeleteTimelines({anchor}) then error('Could not remove format anchor') end
      anchor=nil
      if not rushs:SetName(TIMELINE_NAME) then error('Could not name timeline: ' .. TIMELINE_NAME) end
      local graph=rushs:GetNodeGraph()
      if not graph or graph:GetNumNodes()~=2 or not graph:SetNodeEnabled(1,true) or not graph:SetNodeEnabled(2,false) then
        error('Could not prepare timeline CST states; Rec.709 export node must remain disabled')
      end
      -- DRT imports reset project format. Apply project settings AFTER both model imports.
      local settings={
        {'colorScienceMode','davinciYRGB'}, {'separateColorSpaceAndGamma','1'},
        {'colorSpaceTimeline','DaVinci WG'}, {'colorSpaceTimelineGamma','DaVinci Intermediate'},
        {'colorSpaceOutput','DaVinci WG'}, {'colorSpaceOutputGamma','DaVinci Intermediate'},
        {'timelineFrameRate',tostring(shoot.fps)},
        {'timelineInputResMismatchBehavior','scaleToFit'},
        {'timelineResolutionWidth',tostring(studio and shoot.width or math.min(shoot.width,3840))},
        {'timelineResolutionHeight',tostring(studio and shoot.height or math.min(shoot.height,2160))}}
      for _,setting in ipairs(settings) do
        -- Resolve 21 exposes the output gamma for reading but rejects Intermediate in its setter.
        -- The bundled DRP carries it; retain an already matching value.
        local readable,current=pcall(function() return project:GetSetting(setting[1]) end)
        if not readable or tostring(current)~=setting[2] then
          if not project:SetSetting(setting[1],setting[2]) then error(shoot.name .. ': setting refused ' .. setting[1]) end
        end
      end
      -- Playback rate is read-only in the API and is prepared in the project model.
      local playback=tonumber(project:GetSetting('timelinePlaybackFrameRate'))
      if playback and math.abs(playback-shoot.fps)>0.001 then error('Project playback frame rate does not match the prepared model') end
      -- The project owns format, cadence and colour. Imported models must inherit it.
      if not rushs:SetSetting('useCustomSettings','0') then error('Could not inherit project settings') end
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
          local sizingApplied=c.factor==1
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
              sizingApplied=video:SetClipProperty('Input Sizing Preset',wanted)
              if not sizingApplied and not INCLUDE_ALL_SHOTS then warn(c.name .. ': sizing preset missing ' .. wanted) end
            else
              sizingApplied=true -- Preserve a user's custom input sizing.
              if preset~=wanted then warn(c.name .. ': existing sizing preset kept') end
            end
          end
          if rushs and INCLUDE_ALL_SHOTS then
            local timelineItems=pool:AppendToTimeline({video}) or {}
            if #timelineItems==0 then warn(c.name .. ': timeline append refused') end
            for _,item in ipairs(timelineItems) do
              if gyroSource and (not gyroSource:CopyGrades({item}) or not hasGyro(item)) then
                warn(c.name .. ': Gyroflow(NiYien) node could not be applied')
              end
              local rawFit=math.min(targetWidth/c.width,targetHeight/c.height)
              local zoom=math.min(1,math.min(targetWidth/(c.width*c.factor),targetHeight/c.height)/rawFit)
              local x,y=1,1
              if not sizingApplied then x=c.factor*zoom; y=zoom
              elseif not studio then x=zoom; y=zoom end
              if not item:SetProperty('ZoomGang',false) or not item:SetProperty('ZoomX',x) or not item:SetProperty('ZoomY',y) then
                warn(c.name .. ': desqueeze/fit transform refused')
              end
            end
          end
        end)
        if not success then failed=failed+1; warn(c.name .. ': ' .. tostring(reason)) end
      end
    end
    cleanupPending()
    cleanupPending=nil
    if not pm:SaveProject() then error(shoot.name .. ': project save refused') end
    if CREATE_ONLY then
      local db=pm:GetCurrentDatabase()
      if type(db)=='table' and db.DbName then
        local function hex(s) return (s:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)) end
        local identity=(db.DbType or '') .. '|' .. (db.IpAddress or '') .. '|' .. db.DbName
        for _,source in ipairs(shoot.sources or {shoot.source}) do
        local receipt='LINK ' .. hex(source) .. ' ' .. hex(shoot.name) .. ' ' .. hex(identity)
        print(receipt)
        if RECEIPTS then
          local f=io.open(RECEIPTS,'a')
          if f then f:write(receipt .. '\n'); f:close() else warn('Could not remember linked project') end
        end
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
if not ok then
  if cleanupPending then
    local cleaned,reason=pcall(cleanupPending)
    if not cleaned then warn('Temporary model cleanup failed: ' .. tostring(reason)) end
  end
  print('ERROR ' .. clean(err))
  if MENU then dialog(tostring(err),false) end
end
end
