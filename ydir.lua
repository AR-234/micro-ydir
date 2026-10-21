local micro     =  import("micro")
local shell     =  import("micro/shell")
local buffer    =  import("micro/buffer")
local config    =  import("micro/config")
local os        =  import("os")
local io   		=  import("io")
local ioutil    =  import("io/ioutil")
local filepath  =  import("path/filepath")
local time      =  import("time")
local fmt 		=  import("fmt")
local runtime   =  import("runtime")

local YDIR_BUFFER_TYPE_READONLY      =  "ydir"
local YDIR_BUFFER_TYPE_WRITEABLE     =  "ydir-writeable"  -- TODO: implement writeable mode
local YDIR_LISTING_START             =  3 				  -- FIXME: need to find a better way, there are (YDIR_LISTING_START-1) in the code since some values are 0 based others are not..
local YDIR_BACKSPACE_HISTORY_LENGTH  =  100

local NERD_DIR = ""
local NERD_FILE= ""
local NERD_LOOKUP = {
	-- Text
	["readme"]	="",	["license"]	="",
	[".txt"]	="",
	-- Markup
	[".md"]		="󰽛",	[".html"]	="",
	[".css"]	="",	[".scss"]	="",
	-- Code
	[".lua"] 	="",	[".c"]		="",
	[".cpp"]	="",	[".cs"]		="",
	[".py"]		="",	[".php"]	="",
	[".sh"]		="",	[".java"] 	="",
	[".js"]		="",	["makefile"]="",
	[".go"]		="󰟓",	[".ts"]		="",
	[".kt"]		="",	[".svelte"] ="",
	[".vue"]	="",	
	-- Storage
	[".lock"]	="",	[".gitignore"]="",
	[".yml"]	="",	[".yaml"]	="",	
	[".json"]	="",	[".xml"]	="󰗀",
	[".ini"]	="",	[".cfg"]	="",
	[".sql"]	="",	[".toml"]	="",
	[".csv"]	="",	[".db"]		="",
	-- Media
	[".png"]	="",	[".jpg"]	="",
	[".gif"]	="",	[".svg"]	="",
	-- Misc
	[".zip"]	="",	[".pdf"]	="",
	[".wasm"]   ="",	[".gz"]		="",
}

--
-- General helper functions
--

-- AI-Clanker code:
-- My bitmagic skills aren't that great, need to validate this, 
-- but looks alright on the first look: https://pkg.go.dev/io/fs#FileInfo
local function hasbit(mode, n) -- bool
    return math.floor(mode / 2^n) % 2 == 1
end -- hasbit

local function is_regular(mode)
    for _, n in ipairs({31, 27, 26, 25, 24, 21, 19}) do
        if hasbit(mode, n) then return false end
    end
    return true
end -- is_regular

function fmode_to_string(mode) -- string
    local kind = "-"
    if     hasbit(mode, 31) then kind = "d"                 -- ModeDir
    elseif hasbit(mode, 27) then kind = "l"                 -- ModeSymlink
    elseif hasbit(mode, 25) then kind = "p"                 -- ModeNamedPipe
    elseif hasbit(mode, 24) then kind = "s"                 -- ModeSocket
    elseif hasbit(mode, 26) then                            -- ModeDevice
        kind = hasbit(mode, 21) and "c" or "b"              -- ModeCharDevice
    end

    -- rwx bits: bit 8 down to bit 0
    local rwx = {"r", "w", "x"}
    local out = {}
    for i = 0, 8 do
            out[i + 1] = hasbit(mode, 8 - i) and rwx[(i % 3) + 1] or "-"
        end

    -- setuid (bit 23), setgid (bit 22), sticky (bit 20), shown like ls
    if hasbit(mode, 23) then out[3] = (out[3] == "x") and "s" or "S" end
    if hasbit(mode, 22) then out[6] = (out[6] == "x") and "s" or "S" end
    if hasbit(mode, 20) then out[9] = (out[9] == "x") and "t" or "T" end

    return kind .. table.concat(out)
end -- fmode_to_strings
-- end of ai

local function starts_with(str, prefix) -- bool
  return str:sub(1, #prefix) == prefix
end -- starts_with

local function command_options(opts) -- fun
	return function (bp)
		local line = bp:Line(0)
		local before = line:sub(1, bp:GetActiveCursor().X)
		local input = before:match("([^%s]*)$") or ""
        local completions = {}
        local suggestions = {}
        for _, opt in ipairs(opts) do
            if starts_with(opt, input) then
                table.insert(suggestions, opt)
                table.insert(completions, opt:sub(#input + 1))
            end
        end
        return completions, suggestions
	end
end -- options

local function copy_single(src, dst) -- string(error)/nil
	local info, err = os.Lstat(src)
	if err ~= nil then return err:Error() end
	local perm = info:Mode() % 512
	if info:IsDir() then
		-- Check for recursion
		if starts_with(dst, src) then
			-- FIXME: more meaningful error
			return "Recursion detected, abort"
		end
	
		err = os.MkdirAll(dst, perm)
		if err ~= nil then return err:Error() end
		
		local entries, derr = ioutil.ReadDir(src)
		if derr ~= nil then return err:Error() end
		for i=1, #entries do
			local name = entries[i]:Name()
			err = copy_single(
				filepath.Join(src, name),
				filepath.Join(dst, name)
			)
			if err ~= nil then return err:Error() end
		end
		return nil
	end

	if not is_regular(info:Mode()) then
		local target, serr = os.Readlink(src)
		if serr ~= nil then return serr:Error() end
		err = os.Symlink(target, dst)
		if err ~= nil then return err:Error() end
		return nil
	end

	local input, ferr = os.Open(src)
	if ferr ~= nil then return ferr:Error() end
	
	local output,ferr2 = os.OpenFile(
		dst,
		-- https://gist.github.com/thiagozs/85f93d58e4f5aebc71f7f95033206829
		os.O_WRONLY		-- Opens the file as write-only. If the file exists, its contents are truncated. If it doesn't exist, a new file is created.
		+ os.O_CREATE	-- Creates a new file if it doesn't exist.
		+ os.O_EXCL,	-- Used with O_CREATE, it ensures that the file is created exclusively, preventing creation if it already exists.
		perm
	)
	if ferr2 ~= nil then 
		input:Close()
		return ferr2 
	end

	local _, cerr = io.Copy(output, input)
	input:Close()
	if cerr ~= nil then return cerr:Error() end
	err = output:Close()
	return err
end -- copy_single

local function copy_paths(src_paths, dst) -- string(error)/nil
	for i=1, #src_paths do
		local src = src_paths[i]
		local target = filepath.Join(dst, filepath.Base(src))
		local err = copy_single(src, target)
		if err ~= nil then return err:Error() end
	end
	return nil
end -- copy_paths

local function move_single(src, dst) -- string(error)/nil
	local err = os.Rename(src, dst)
	if err ~= nil then
		err = copy_single(src, dst)
		if err ~= nil then return err:Error() end
		err = os.RemoveAll(src)
		return err:Error()
	end
end -- move_single

local function move_paths(src_paths, dst) -- string(error)/nil
	for i=1, #src_paths do
		local src = src_paths[i]
		local target = filepath.Join(dst, filepath.Base(src))
		local err = move_single(src, target)
		if err ~= nil then return err:Error() end
	end
	return nil
end -- move_paths

local function create_path(base, rel_path) -- bool
	local path = filepath.Join(base, rel_path)
	local is_dir = rel_path:sub(-1) == "/"
	
	local dir = path
	if not is_dir then dir = filepath.Dir(path) end	
	
    local err = os.MkdirAll(dir, 493) -- 493 = 0755
    if err ~= nil then
  	    micro.InfoBar():Error(err)
        return false
    end

	if is_dir then return true end

    -- don't truncate an existing file
    local _, serr = os.Stat(path)
    if serr == nil then
        micro.InfoBar():Error("File `"..path.."` already exists!")
        return false
    end

    local err = ioutil.WriteFile(path, "", 420)
    if err ~= nil then
 	    micro.InfoBar():Error(err)
       return false
   	end	
   	return true
end -- create_path

function ydir_buffer_type(bp) -- string/nil
	if bp.Buf:FileType() == YDIR_BUFFER_TYPE_READONLY  then return "readonly"  end
	if bp.Buf:FileType() == YDIR_BUFFER_TYPE_WRITEABLE then return "writeable" end
	return nil
end -- ydir_buffer_type

function is_ydir_buffer(bp) -- bool	
	return ydir_buffer_type(bp) ~= nil
end -- is_ydir_buffer

--
-- Backspace History
--

local backspace_history = {}
local backspace_history_idx = 1

local function get_history_index(path) -- int/nil
	for i=1, #backspace_history do
	  if backspace_history[i] and path == backspace_history[i]["path"] then
		return i
	  end
	end
	return nil
end -- get_history_index

local function get_history(path) -- string/nil
	local idx = get_history_index(path)
	if idx == nil then return nil end
	return backspace_history[idx]["element"]
end -- get_history

local function add_history(path, entry) -- void
	idx = get_history_index(path)
	if idx ~= nil then
	    -- Already in history, delete this one
		backspace_history[idx] = nil
	end

	-- Add Path to the history
	backspace_history[backspace_history_idx] = {
		  	path = path,
		  	element  = entry,
		}

	-- Increment backspace_history_idx 
	backspace_history_idx = backspace_history_idx + 1
	if backspace_history_idx > YDIR_BACKSPACE_HISTORY_LENGTH then
		backspace_history_idx = 1
	end
end -- add_history

---
--- Buffer format functions
---

-- Fixed size: 6
local function format_size(size) -- string
  if not size then return "  N/A " end

  if size < 1000 then
    return string.format("%5dB", size)
  end

  local units = { "K", "M", "G", "T", "P" }
  local value, i = size / 1024, 1

  -- Had problems with overflowing, probably rounding
  -- Hack seems to fix this
  while value >= 999.95 and i < #units do
    value = value / 1024
    i = i + 1
  end

  return string.format("%5.1f%s", value, units[i])
end -- format_size

-- Fixed size: 12
local function format_date(t) -- string
	local age = time.Now():Unix() - t:Unix()
    if age < 0 or age > config.GetGlobalOption("ydir.DateSwitchAmount") then
        return t:Format("Jan _2  2006")
    else
        return t:Format("Jan _2 15:04")
    end
end -- format_date

-- Fixed size: 10
local function format_perm(perm) -- string
	return fmode_to_string(perm)
end -- format_perm

--
-- Buffer display functions
--

local function dir_as_list(path) -- arr<string>, err
	local entries, err = ioutil.ReadDir(path)
    if err ~= nil then return nil, err end
    local output = {}
	local files  = {}
	
	for i = 1, #entries do
  		local entry = entries[i]
 		local name  = entry:Name()
  	    local fileinfo, serr = os.Lstat(filepath.Join(path, name))
 		if serr == nil then
 			local isDir = fileinfo:IsDir()
 			if isDir then
 				table.insert(output, name .. "/")
 			else
			 	table.insert(files, name)
 			end
 		end
  	end

	table.sort(output)
	table.sort(files)
	
	for i = 1, #files do
 		table.insert(output, files[i])
  	end

    -- TODO: Add guard for root folder (?)
   	table.insert(output, 1, "..")
   	
   	return output, nil
end -- dir_as_list

-- 1-based position
local function path_to_position(base, entries, path) -- int/nil
	for i = 1, #entries do
		local name  = entries[i]
		local abs, err = filepath.Abs(filepath.Join(base, name))
		if err == nil and path == abs then
			return i-1 
		end
	end
	return nil
end -- path_to_position

function ydir_file_name_start() -- int
	local hide_date = config.GetGlobalOption("ydir.HideDate")
	local hide_perm = config.GetGlobalOption("ydir.HidePermission")
	local hide_size = config.GetGlobalOption("ydir.HideSize")
	local has_nerdfont = config.GetGlobalOption("ydir.Nerdfont")
	
	local width     =    2   -- Special markers
	width = width   +    1   -- Spacing
	if not hide_size then 
		width = width +  6   -- Size
		width = width +  2   -- Spacing
	end
	if not hide_date then 
		width = width + 12   -- Date
		width = width +  2   -- Spacing
		end
	if not hide_perm then 
		width = width + 10   -- Perm
		width = width +  2   -- Spacing
	end
	if has_nerdfont then
		width = width + 4
	end
	
	return width
end -- ydir_file_name_start

local function set_cursor_to_idx(bp, idx, opts) -- nil
	if idx == nil then idx = 0 end
	if idx >= bp.Buf:LinesNum()-YDIR_LISTING_START-1  then idx = bp.Buf:LinesNum()-YDIR_LISTING_START-1 end
	-- Scroll up, so header is visible if possible
	bp:CursorStart() 

	-- Nerdfont offset
	has_nerd    = config.GetGlobalOption("ydir.Nerdfont")
	nerd_select = config.GetGlobalOption("ydir.NerdfontIconSelect")
	offset = 0
	if has_nerd then
		if nerd_select then
			offset = 4
		else
			offset = 2
		end
	end
	
	-- Set cursor to the selection
	bp.Cursor:GotoLoc(buffer.Loc(ydir_file_name_start()-offset, YDIR_LISTING_START - 1 + idx))
	bp:Relocate()
end -- set_cursor_to_idx

local function text_generator(base_path, entries) -- string, err
	local hide_date = config.GetGlobalOption("ydir.HideDate")
	local hide_perm = config.GetGlobalOption("ydir.HidePermission")
	local hide_size = config.GetGlobalOption("ydir.HideSize")
	local has_nerdfont = config.GetGlobalOption("ydir.Nerdfont")

	lines = {}
	-- Header
	table.insert(lines, base_path)
	table.insert(lines, "")

	for i = 1, #entries do
		local name  = entries[i]
		--https://pkg.go.dev/io/fs#FileInfo
		local fileinfo, serr = os.Lstat(filepath.Join(base_path, name))
		if serr == nil then
		    --              Marker
		    --              |Selection
		    --              ||Spacing
		    --              |||
			local text =   "   "
			--             Date
			if not hide_date then 
				text = text .. format_date(fileinfo:ModTime()) .. "  "
			end
			--             Perm
			if not hide_perm then 
				text = text .. format_perm(fileinfo:Mode()) .. "  "
			end
			--             Show perm
			if not hide_size then 
				text = text .. format_size(fileinfo:Size()) .. "  "
			end 
			--             Show Nerdfont
			if has_nerdfont then
				symbol = NERD_FILE
				pos=#name
				while pos > 1 do
					if name:sub(pos,pos) == "." then break end
					pos = pos - 1
				end
				ext = name:sub(pos,#name)

				if fileinfo:IsDir() then
					symbol = NERD_DIR
				elseif NERD_LOOKUP[ext:lower()] ~= nil then
					symbol = NERD_LOOKUP[ext:lower()]
				end
				
				text = text .. symbol .. " "
			end
			--             Lastly append the name
			text = text .. name
			table.insert(lines, text)
		end
    end
	local text = table.concat(lines, "\n") .. "\n"
    return text, nil
end -- text_generator

local function update_buffer(bp, path, cursor_path) -- nil
	local entries, err = dir_as_list(path)
    if err ~= nil then 
      	micro.InfoBar():Error("ydir failed: ", err)
		return 
	end
	local text, err = text_generator(path, entries)
	if err ~= nil then 
      	micro.InfoBar():Error("ydir failed: ", err)
		return 
	end
	local b = bp.Buf
    b:Replace(b:Start(), b:End(), text)

    local cursor_idx = path_to_position(path, entries, cursor_path)
    set_cursor_to_idx(bp, cursor_idx)
end -- update_buffer

function ydir(bp, args) -- nil
	pane = config.GetGlobalOption("ydir.Default")
	if args and #args > 0 then
		if args[1]:lower() == "vsplit" then
			pane = "vsplit"
		elseif args[1]:lower() == "hsplit" then
			pane = "hsplit"
		elseif args[1]:lower() == "tab" then
			pane = "tab"
		elseif args[1]:lower() == "current" then
			pane = "current"
		else
        	micro.InfoBar():Error("Unsupported pane mode: " + args[1])
        	return
        end
    end
	
    local b = buffer.NewBuffer("", "")
 	b:SetName("ydir")
 	b:SetOption("filetype", YDIR_BUFFER_TYPE_READONLY)
	b.Type.Scratch  = true
 	b.Type.Readonly = true
 	
 	local initial_selection = bp.Buf.AbsPath
 	local base_path = filepath.Dir(initial_selection)
 	local fileinfo, serr = os.Lstat(initial_selection)
	if serr ~= nil or fileinfo:IsDir() then
		base_path = os.Getwd()
	end
	
	if pane == "vsplit" then
		bp:VSplitAction()
	elseif pane == "hsplit" then
 		bp:HSplitAction()
 	elseif pane == "tab" then
 		bp:AddTab()
 	else
 		if config.GetGlobalOption("ydir.SaveBufWhenOpenOnCurrent") then
			bp:Save()
 		end
 	end
 	
	micro.CurPane():OpenBuffer(b)	
 	update_buffer(micro.CurPane(), base_path, initial_selection)
end -- ydir

--
-- Buffer navigation helper functions
--

local function get_file_name_by_line(bp, y) -- string/nil
	if y < YDIR_LISTING_START-1 then return nil end
	if y > bp.Buf:LinesNum()-1  then return nil end
	local line = bp.Buf:Line(y)
	start = ydir_file_name_start()
	if #line <= start then return nil end
	return line:sub(start+1)
end -- get_file_name_by_line

local function get_file_name_on_cursor(bp) -- string/nil
	local y = bp.Cursor.Y
	return get_file_name_by_line(bp, y)
end -- get_file_name_on_cursor

local function get_current_dir(bp) -- string
	return bp.Buf:Line(0)
end -- get_current_dir

--
-- Selection
--

local function is_line_selected(bp, y) -- bool
	if y < YDIR_LISTING_START   then return false end
	if y > bp.Buf:LinesNum()-1  then return false end
	
	local line = bp.Buf:Line(y)
	return line:sub(2, 2) == "*"
end -- is_line_selected

local function mark_line_selected(bp, y) -- bool
	if y < YDIR_LISTING_START   then return false end
	if y > bp.Buf:LinesNum()-2  then return false end
    bp.Buf:Replace(
    		buffer.Loc(1, y), 
    		buffer.Loc(2, y), 
    		"*")
   	return true
end -- mark_line_selected

local function unmark_line_selected(bp, y) -- bool
	if y <  YDIR_LISTING_START   then return false end
	if y > bp.Buf:LinesNum()-2  then return false end
	bp.Buf:Replace(
	    		buffer.Loc(1, y), 
	    		buffer.Loc(2, y), 
	    		" ")
	return true
end -- unmark_line_selected

local function toggle_selection(bp, y) -- nil
	if is_line_selected(bp, y) then
		unmark_line_selected(bp, y)
	else
		mark_line_selected(bp, y)
	end
end -- toggle_selection

function ydir_smart_mark(bp) -- nil
	if not bp.Cursor:HasSelection() then
		local y = bp.Cursor.Y
		toggle_selection(bp, y)
	    return false
	end
	
	local sel = bp.Cursor.CurSelection
	local s, e = sel[1], sel[2]
	local min  = math.min(s.Y, e.Y)
	local max = math.max(s.Y, e.Y)

	local all_marked = true
	for i = min, max do
		if not is_line_selected(bp, i) then
			
			all_marked = false
		end
	end
	
	if all_marked then
		for i = min, max do
			unmark_line_selected(bp, i)
		end
	else
		for i = min, max do
			mark_line_selected(bp, i)
		end
	end
end -- ydir_smart_mark

local function are_files_selected(bp) -- bool
	for i = YDIR_LISTING_START-1, bp.Buf:LinesNum()-1 do
		if is_line_selected(bp, i) then
			return true
		end
	end	
	return false
end -- are_files_selected

local function get_files_selected(bp) -- arr<path>
	entries = {}
	for i = YDIR_LISTING_START-1, bp.Buf:LinesNum()-1 do
		if is_line_selected(bp, i) then
			entries[#entries+1] = get_file_name_by_line(bp, i)
		end
	end
	
	-- If entries is empty use the file on cursor
	if #entries == 0 then
		if bp.Cursor.Y == YDIR_LISTING_START-1 then return {} end
 		if bp.Cursor.Y == bp.Buf:LinesNum()-1  then return {} end
		 		 		 
		local file, err = get_file_name_on_cursor(bp)
		if err == nil then
			entries[1] = file
		end
	end
	
	return entries
end -- get_files_selected

--
-- Cut/Copy/Paste
--

local paste_storage = {
	mode  = nil,
	base  = nil,
	paths = {}
}

local function set_paste_abs_paths(bp) -- nil
	local selection    = get_files_selected(bp)
    local current_path = get_current_dir(bp)
    paste_storage["base"]  = current_path
	paste_storage["paths"] = {}
	for i=1, #selection do
   		local abs_path = filepath.Join( current_path, selection[i] )
		paste_storage["paths"][(#paste_storage["paths"])+1] = abs_path
	end
end -- set_paste_abs_paths

function ydir_copy(bp) -- nil
	paste_storage["mode"] = "copy"
	set_paste_abs_paths(bp)
	micro.InfoBar():Message("Copied " .. #paste_storage["paths"] .. " files")
end -- ydir_copy

function ydir_cut(bp) -- nil
	paste_storage["mode"] = "cut"
	set_paste_abs_paths(bp)
	micro.InfoBar():Message("Cut " .. #paste_storage["paths"] .. " files")
end -- ydir_cut

function ydir_paste(bp) -- nil
	if paste_storage["mode"] == nil then return end
    local current_path = get_current_dir(bp)
	if paste_storage["mode"] == "copy" then
		local err = copy_paths(paste_storage["paths"], current_path)
		if err ~= nil then
	        micro.InfoBar():Error(err)
		end
	elseif paste_storage["mode"] == "cut" then
		local err = move_paths(paste_storage["paths"], current_path)
		if err ~= nil then
	        micro.InfoBar():Error(err)
		end
		paste_storage["mode"]  = nil
		paste_storage["base"]  = nil
		paste_storage["paths"] = {}
	end

	local line = bp.Cursor.Y
    local current_path = get_current_dir(bp)
  	update_buffer(bp, current_path, nil)
  	set_cursor_to_idx(bp, line+1-YDIR_LISTING_START, {})
end -- ydir_paste

--
-- COMMAND FUNCTIONS
-- 
function ydir_open_cursor(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	if bp.Cursor.Y < (YDIR_LISTING_START-1) then return false end
	
	local name = get_file_name_on_cursor(bp)
    if not name then return false end

    -- Get file stats
    local current_path = get_current_dir(bp)
   	local future_path = filepath.Join( current_path, name )
   	local fileinfo, serr = os.Lstat(future_path)
	if serr ~= nil then
		micro.InfoBar():Error("open failed: ", name)
		return false
	end

	-- Handle directories
	if fileinfo:IsDir() then
		local last = get_history(future_path)
		if last ~= nil then
			last = filepath.Join(future_path, last)
		end
		update_buffer(bp, future_path, last)
		return false
	end
	
	-- Handle files
	local b, err = buffer.NewBufferFromFile(future_path)
	local path = os.Getwd()

	-- Change the display name from abs path to relative path if the file
	-- is in the working directory
	local display_name = b:GetName()
	if display_name and display_name:sub(1, #path) == path then
		b:SetName(display_name:sub(#path+2))
	end
	
	bp:OpenBuffer(b)
    return false
end -- ydir_open_cursor

function ydir_open_parent(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	
	local current_path = get_current_dir(bp)
    local future_path = filepath.Join(current_path, "..")
    
    add_history(current_path, get_file_name_on_cursor(bp))
    
    update_buffer(bp, future_path, current_path)
    return false
end -- ydir_open_parent

function ydir_create_path(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	micro.InfoBar():Prompt("Create Path: ","","CreatePath",function(resp) end,
      function(resp, canceled)
        if canceled then return end
        if resp == "" then return end
        local current_path = get_current_dir(bp)
	    local rel = filepath.ToSlash(resp)
     	create_path(current_path, rel)

        local line = bp.Cursor.Y
	    local current_path = get_current_dir(bp)
		local idx = rel:find("/", 1, true)  -- 1-based index of the first "/", plain (no pattern)
		local first
		if idx == nil then
			first = rel                      -- no slash: the whole thing is the first component
		else
			first = rel:sub(1, idx - 1)      -- everything before the first slash
		end
   		local abs_path = filepath.Join(current_path, first)
		  
	    update_buffer(bp, current_path, abs_path)
      end)
	return true
end -- ydir_create_path

function ydir_delete_selection(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	local current_path = get_current_dir(bp)
	local selection = get_files_selected(bp)
	
	local any_dir = false
	if #selection == 0 then
		return true
	end
	for i=1, #selection do
		local path = filepath.Join(current_path, selection[i])
		local info, err = os.Stat(path)
	    if err ~= nil then
	        micro.InfoBar():Error("Cannot access: " .. path)
	        return true
	    end
	    if path == current_path then
	        micro.InfoBar():Error("Cannot delete folder you are in")
	    end
	    if info:IsDir() then
			any_dir = true
	    end
	end
    
	local function callback(objects) -- nil
		for i=1, #objects do
			local path = filepath.Join(current_path, objects[i])
			local info, err = os.Stat(path)
		    if err ~= nil then
		        micro.InfoBar():Error("Cannot access: " .. path)
		        return true
		    end
		    local delete_err = os.RemoveAll(path)
		    if delete_err ~= nil then
	    		micro.InfoBar():Error("Delete failed: " .. tostring(rerr))
	            return
	       	end
	    end
	    
   	   	micro.InfoBar():Message("Deleted " .. #selection .. " objects")
   	   	
	    local line = bp.Cursor.Y
        local current_path = get_current_dir(bp)
      	update_buffer(bp, current_path, nil)
      	set_cursor_to_idx(bp, line+1-YDIR_LISTING_START, {})
	end -- callback
	
	if any_dir then
			local text = "Delete DIRECTORIES in " .. #selection .. " objects recursivly? (yes,no,esc) "
			if #selection == 1 then
				text = "Delete DIRECTORY `" .. selection[1] .. "` recursivly? (yes,no,esc) "
			end
			micro.InfoBar():Prompt(text,"","DeletePath",function(resp) end,
		            function(resp, canceled)
		                if canceled then return end
		                if resp:lower() == "yes" then
		                    callback(selection)
		                else
		                    micro.InfoBar():Message("Delete cancelled")
		                end
		            end)
	    else
	    	local text = "Delete " .. #selection .. " objects? (y,n,esc)"
	    	if #selection == 1 then
 				text = "Delete file `" .. selection[1] .. "`? (y,n,esc) "
			end
	        micro.InfoBar():YNPrompt(text,
	            function(yes, canceled)
	                if canceled or not yes then return end
	                callback(selection)
	            end)
	    end
    return true
end -- ydir_delete_selection

function ydir_cursor_start(bp) -- nil
	set_cursor_to_idx(bp, 0, {})
end -- ydir_cursor_start

function ydir_cursor_end(bp) -- nil
	local last_line = bp.Buf:LinesNum()-1
	local last_idx = last_line-YDIR_LISTING_START
	set_cursor_to_idx(bp, last_idx, {})	
end -- ydir_cursor_end

--
-- HOOKS!
--
function preInsertNewline(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	return ydir_open_cursor(bp)	
end -- preInsertNewline

function preBackspace(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
    return ydir_open_parent(bp)
end -- preBackspace

function preToggleOverwriteMode(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	ydir_create_path(bp)
    return false
end -- preToggleOverwriteMode

function preDelete(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
    return ydir_delete_selection(bp)
end -- preDelete

function preCursorUp(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	if bp.Cursor.Y < YDIR_LISTING_START then
		ydir_cursor_end(bp)
		return false 
	end
	return true
end -- preCursorUp

function preCursorDown(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	if bp.Cursor.Y > bp.Buf:LinesNum()-YDIR_LISTING_START then
		ydir_cursor_start(bp)
		return false 
	end
	return true
end -- preCursorDown

function preCursorLeft(bp) -- bool
	if not config.GetGlobalOption("ydir.HorizontalCursorMovement") then return true end
	if not is_ydir_buffer(bp) then return true end
    return ydir_open_parent(bp)
end -- preCursorLeft

function preCursorRight(bp) -- bool
	if not config.GetGlobalOption("ydir.HorizontalCursorMovement") then return true end
	if not is_ydir_buffer(bp) then return true end
    return ydir_open_cursor(bp)
end -- preCursorRight

function preCursorStart(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	ydir_cursor_start(bp)	
    return false
end -- preCursorStart

function preCursorEnd(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	ydir_cursor_end(bp)
    return false
end -- preCursorEnd

function preIndentSelection(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	ydir_smart_mark(bp)
	return false
end -- preIndentSelection

--
-- Cut/Copy/Paste support
--

function prePaste(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
	ydir_paste(bp)
    return false
end -- prePaste

function preCutLine(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
    ydir_cut(bp)
    return false
end -- preCutLine

function preCopyLine(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
    ydir_copy(bp)
    return false
end -- preCopyLine

--
-- Mouse support
--
local has_mouse_been_dragged = false

function onMousePress(bp, event) -- nil
	has_mouse_been_dragged = false
end -- onMousePress

function onMouseDrag(bp, event) -- nil
	has_mouse_been_dragged = true
end -- onMouseDrag

function onMouseRelease(bp,event) -- nil
	if not has_mouse_been_dragged and not bp.Cursor:HasSelection() and is_ydir_buffer(bp) then
	    local x, y = event:Position()
	    local loc = bp:LocFromVisual(buffer.Loc(x, y))
	    if loc.Y >= YDIR_LISTING_START-1 and loc.Y < bp.Buf:LinesNum() - 1 then
        	ydir_open_cursor(bp)
	    end
	end
	has_mouse_been_dragged = false
end -- onMouseRelease

function MouseRightClick(bp) -- bool
	if not is_ydir_buffer(bp) then return true end
    return ydir_open_parent(bp)
end -- MouseRightClick

--
-- Base functions
--

function preShellMode(bp) -- bool
	if not is_ydir_buffer(bp) then return true end

	local dir = get_current_dir(bp)	 
    micro.InfoBar():Prompt(dir.."$ ", "", "Shell", nil, function(input, canceled)
        if canceled or input == "" then
            return
        end

		local line = bp.Cursor.Y
        local current_path = get_current_dir(bp)
        local prev = os.Getwd()

		bp:HandleCommand("cd \""..current_path.."\"")
		shell.RunInteractiveShell(input, true, false)
		bp:HandleCommand("cd \""..prev.."\"")

      	update_buffer(bp, current_path, nil)
      	set_cursor_to_idx(bp, line+1-YDIR_LISTING_START, {})
    end)
    
    return false 
end -- preShellMode

function init() -- nil
    config.MakeCommand("ydir", ydir, command_options({"current","hsplit", "tab", "vsplit"}))
    
    config.MakeCommand("ydir_open",  ydir_open_cursor,      config.NoComplete)
    config.MakeCommand("ydir_back",	 ydir_open_parent,      config.NoComplete)
    config.MakeCommand("ydir_create",ydir_create_path,      config.NoComplete)
    config.MakeCommand("ydir_delete",ydir_delete_selection, config.NoComplete)
	config.MakeCommand("ydir_mark",  ydir_smart_mark,       config.NoComplete)

	config.MakeCommand("ydir_copy",  ydir_copy,             config.NoComplete)
	config.MakeCommand("ydir_cut",   ydir_cut,              config.NoComplete)
	config.MakeCommand("ydir_paste", ydir_paste,            config.NoComplete)

    config.RegisterCommonOption("ydir", "Default", "current")
    config.RegisterCommonOption("ydir", "SaveBufWhenOpenOnCurrent", true)
    config.RegisterCommonOption("ydir", "DateSwitchAmount", 15552000) -- Default ~6 Months, value in seconds
    config.RegisterCommonOption("ydir", "HorizontalCursorMovement", true)

    config.RegisterCommonOption("ydir", "HideDate", false)
    config.RegisterCommonOption("ydir", "HideSize", false)
    config.RegisterCommonOption("ydir", "HidePermission", false)
    config.RegisterCommonOption("ydir", "Nerdfont", false)
    config.RegisterCommonOption("ydir", "NerdfontIconSelect", false)
end -- init
