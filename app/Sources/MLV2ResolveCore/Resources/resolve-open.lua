-- SPDX-License-Identifier: GPL-3.0-or-later
local function clean(s) return tostring(s):gsub('[\r\n]',' ') end
local r=resolve
if not r then local ok,v=pcall(function() return Resolve() end); if ok then r=v end end
if not r then print('NO_RESOLVE'); return end
local pm=r:GetProjectManager()
local function database()
  local d=pm:GetCurrentDatabase()
  if type(d)~='table' or not d.DbName then return nil end
  return (d.DbType or '') .. '|' .. (d.IpAddress or '') .. '|' .. d.DbName
end
local function confirm(current)
  if not MENU then print('SWITCH ' .. clean(current)); return false end
  local msg=TEXT.switch .. '\n' .. current .. ' → ' .. TARGET
  local function apple(s) return '"' .. s:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"' end
  local source='display dialog ' .. apple(msg) .. ' buttons {' .. apple(TEXT.cancel) .. ',' .. apple(TEXT.open) .. '} default button 1 cancel button 1'
  local shell="'" .. source:gsub("'", "'\\''") .. "'"
  local result=os.execute('/usr/bin/osascript -e ' .. shell .. ' >/dev/null 2>&1')
  return result==true or result==0
end
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
  if database()~=DATABASE then error('Linked project is in another Resolve library') end
  local current=pm:GetCurrentProject()
  local currentName=current and current:GetName() or nil
  -- Opening a linked project always preserves current work before changing folders.
  local startup=current and emptyStartupProject(current,currentName)
  if currentName and not startup and APPROVED~=currentName then
    if not confirm(currentName) then return end
  end
  if current and not startup and not pm:SaveProject() then error('Could not save current project; switch cancelled') end
  if not pm:GotoRootFolder() then error('Could not open Resolve project root') end
  for _,folder in ipairs(FOLDERS) do
    if not pm:OpenFolder(folder) then error('Linked project folder not found') end
  end
  local exists=false
  for _,name in ipairs(pm:GetProjectListInCurrentFolder() or {}) do if name==TARGET then exists=true end end
  if not exists then error('Linked project not found: ' .. TARGET) end
  if not pm:LoadProject(TARGET) then error('Could not open linked project: ' .. TARGET) end
  print('OPENED')
end)
if not ok then
  print('ERROR ' .. clean(err))
  if MENU then
    local message=tostring(err)
    local apple='"' .. message:gsub('\\','\\\\'):gsub('"','\\"'):gsub('\n','\\n') .. '"'
    local command='display dialog ' .. apple .. ' buttons {"OK"} default button 1'
    os.execute('/usr/bin/osascript -e ' .. "'" .. command:gsub("'", "'\\''") .. "'")
  end
end
