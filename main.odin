package main
import "base:runtime"
import "core:c"
import "core:c/libc"
import "core:sys/linux"
import "core:sys/posix"
import "core:fmt"
import "core:strings"
import "core:mem"
import "core:os"
import "core:time"
import "core:time/timezone"
import "core:time/datetime"
import "core:strconv"
import "vendor:sdl2"
import "vendor:sdl2/ttf"
import "vendor:sdl2/image"
import "vendor:x11/xlib"

XA_CARDINAL : xlib.Atom = 6
XA_WINDOW : xlib.Atom = 33

preferred_font: cstring = "Arial"

TextCache :: struct {
  surface: ^sdl2.Surface,
  icon_surface: ^sdl2.Surface,
  texture: ^sdl2.Texture,
  icon_texture: ^sdl2.Texture,
  window_id: xlib.XID,
  text_width: i32,
  text_height: i32,
  is_active: bool,
  font: ^ttf.Font
}

cache: #soa[dynamic]TextCache

// For caching icon files read from disk
// This is different from the ones in _NET_WM_ICON
IconImageCache :: struct {
  class_name: cstring,
  surface: ^sdl2.Surface,
  is_active: bool
}

icon_image_cache: #soa[dynamic]IconImageCache

DigitTextCache :: struct {
  textures: [101]^sdl2.Texture,
  surfaces: [101]^sdl2.Surface,
  widths: [101]i32,
  heights: [101]i32
}

digit_cache : DigitTextCache

init_digits :: proc(renderer: ^sdl2.Renderer) {
  white : sdl2.Color = {100, 200, 100, 255}

  font: ^ttf.Font
  get_matching_font("abc123", &font)
  if font == nil {
    fmt.panicf("Got a nil font in init_digits")
  }
  defer ttf.CloseFont(font)

  text_width, text_height : i32
  c :[]u8 = {0, 0}
  num_st : cstring
  padded :[2]string
  padded[0] = "0"
  for i in 0..<10 {
    padded[1] = strconv.itoa(c, i)
    num_st = strings.clone_to_cstring(strings.concatenate(padded[:]))
    ttf.SizeUTF8(font, num_st, &text_width, &text_height)
    digit_cache.surfaces[i] = ttf.RenderUTF8_Solid(font, num_st, white)
    digit_cache.textures[i] = sdl2.CreateTextureFromSurface(renderer, digit_cache.surfaces[i])
    digit_cache.widths[i] = text_width
    digit_cache.heights[i] = text_height
  }
  for i in 10..<100 {
    num_st = strings.clone_to_cstring(strconv.itoa(c, i))
    ttf.SizeUTF8(font, num_st, &text_width, &text_height)
    digit_cache.surfaces[i] = ttf.RenderUTF8_Solid(font, num_st, white)
    digit_cache.textures[i] = sdl2.CreateTextureFromSurface(renderer, digit_cache.surfaces[i])
    digit_cache.widths[i] = text_width
    digit_cache.heights[i] = text_height
  }

  ttf.SizeUTF8(font, ":", &text_width, &text_height)
  digit_cache.surfaces[100] = ttf.RenderUTF8_Solid(font, ":", white)
  digit_cache.textures[100] = sdl2.CreateTextureFromSurface(renderer, digit_cache.surfaces[100])
  digit_cache.widths[100] = text_width
  digit_cache.heights[100] = text_height
}

foreign import fontconfig "system:fontconfig"

FcMatrix :: struct {
    xx : c.double,
    xy : c.double,
    yx : c.double,
    yy : c.double
}

FcFontSet  :: struct {
    nfont : c.int,
    sfont : c.int,
    fonts : ^^FcPattern
}

FcConfig :: struct {}
FcPattern :: struct {}
FcCharSet :: struct{}
FcLangSet :: struct{}
FcRange :: struct{}

FcMatchKind :: enum {
    FcMatchPattern,
    FcMatchFont,
    FcMatchScan,
    FcMatchKindEnd,
    FcMatchKindBegin = FcMatchPattern
}

FcResult :: enum {
    FcResultMatch,
    FcResultNoMatch,
    FcResultTypeMismatch,
    FcResultNoId,
    FcResultOutOfMemory
}

FcType :: enum {
    FcTypeUnknown = -1,
    FcTypeVoid,
    FcTypeInteger,
    FcTypeDouble,
    FcTypeString,
    FcTypeBool,
    FcTypeMatrix,
    FcTypeCharSet,
    FcTypeFTFace,
    FcTypeLangSet,
    FcTypeRange
}

FcObjectSet :: struct {
    nobject: c.int,
    sobject: c.int,
    objects: ^^c.char
}

FcValueType :: struct #raw_union {
  s: ^c.uchar,
	i: c.int,
	b: c.int,
	d: c.double,
	m: ^FcMatrix,
	c: ^FcCharSet,
  f: rawptr,
  l: ^FcLangSet,
	r: ^FcRange
}

FcValue :: struct {
  type: FcType,
  u: FcValueType
}

foreign fontconfig {
  FcBlanksCreate :: proc() ---
  FcInitLoadConfigAndFonts :: proc() -> ^FcConfig ---
  FcNameParse :: proc(name: ^c.char) -> ^FcPattern ---
  FcConfigSubstitute :: proc(config: ^FcConfig, p: ^FcPattern, kind: FcMatchKind) ---
  FcDefaultSubstitute :: proc(pattern: ^FcPattern) ---
  FcFontSetCreate :: proc() -> ^FcFontSet ---
  FcObjectSetBuild :: proc(first: ^c.char, #c_vararg args: ..any) -> ^FcObjectSet ---
  FcFontSort :: proc(config: ^FcConfig, p: ^FcPattern, trim: c.int, csp: ^^FcCharSet, result: ^FcResult) -> ^FcFontSet ---
  FcFontRenderPrepare :: proc(config: ^FcConfig, pat: ^FcPattern, font: ^FcPattern) -> ^FcPattern ---
  FcFontSetAdd :: proc(s: ^FcFontSet, font: ^FcPattern) -> c.int ---
  FcFontSetSortDestroy :: proc(fs: ^FcFontSet) ---
  FcPatternDestroy :: proc(p: ^FcPattern) ---
  FcFontSetDestroy :: proc(s: ^FcFontSet) ---
  FcObjectSetDestroy :: proc(os: ^FcObjectSet) ---
  FcPatternFilter :: proc(p: ^FcPattern, os: ^FcObjectSet) -> ^FcPattern ---
  FcPatternGet :: proc(p: ^FcPattern, object: ^c.char, id: c.int, v: ^FcValue) -> FcResult ---
  FcCharSetCreate :: proc() -> ^FcCharSet ---
  FcCharSetDestroy :: proc(cs: ^FcCharSet) -> ^FcCharSet ---
  FcUtf8ToUcs4 :: proc(src_orig: ^c.char, dst: ^c.uint, len: c.int) -> c.int ---
  FcCharSetAddChar :: proc(fcs: ^FcCharSet, ucs4: c.uint) -> c.int ---
  FcPatternAddCharSet :: proc(p: ^FcPattern, object: ^c.char, cs: ^FcCharSet) -> c.int ---
}

handle_bad_window :: proc "c" (display: ^xlib.Display,
                               ev: ^xlib.XErrorEvent) -> i32 {
  return 0
}

handle_io_error :: proc "c" (display: ^xlib.Display) -> i32 {
  return 0
}

get_attributes :: proc(display: ^xlib.Display,
                       window: xlib.XID) -> Maybe(xlib.XWindowAttributes) {
  attrs : xlib.XWindowAttributes
  if xlib.GetWindowAttributes(display, window, &attrs) == cast(i32)xlib.Status.BadWindow {
    return nil
  }
  return attrs
}

cache_active_windows :: proc(display: ^xlib.Display,
                             root_window: xlib.XID,
                             renderer: ^sdl2.Renderer) {
  root_ret : xlib.XID
  parent_ret : xlib.XID
  children_ret : [^]xlib.XID // array of pointers to windows
  n_children_ret : u32
  xlib.QueryTree(display, root_window, &root_ret, &parent_ret, &children_ret, &n_children_ret)

  current_window : xlib.XID

  defer xlib.Free(children_ret)

  unviewable := xlib.WindowMapState.IsUnviewable
  unmapped := xlib.WindowMapState.IsUnmapped

  for i in 0..<n_children_ret {
    current_window = children_ret[i]
    if current_window == root_window {
      continue
    }
    attrs, attrs_ok := get_attributes(display, current_window).?
    if attrs_ok {
      if attrs.map_state == unviewable || attrs.map_state == unmapped {
        continue
      }
      text_set_cached(display, renderer, current_window)
    }
  }
}

text_get_cached :: proc(display: ^xlib.Display,
                        renderer: ^sdl2.Renderer,
                        window_id: xlib.XID) -> Maybe(TextCache) {
  if window_id == 0 {
    fmt.println("got window_id == 0 in text_get_cached")
    return nil
  }
  for v in cache {
    if v.window_id == window_id && v.is_active {
      return v
    }
  }
  return text_set_cached(display, renderer, window_id)
}

text_set_cached :: proc(display: ^xlib.Display,
                        renderer: ^sdl2.Renderer,
                        window_id: xlib.XID) -> Maybe(TextCache) {

  if window_id == 0 {
    fmt.println("got window_id == 0 in text_set_cached")
    return nil
  }

  // If it's already in there find it and free the existing texture/surface first
  found_existing_window := -1
  i := 0
  for &v in cache {
    if v.window_id == window_id && v.is_active {
      found_existing_window = i
      sdl2.FreeSurface(v.surface)
      sdl2.DestroyTexture(v.texture)
      sdl2.FreeSurface(v.icon_surface)
      sdl2.DestroyTexture(v.icon_texture)
      if v.font != nil {
        ttf.CloseFont(v.font)
      }
      v.is_active = false
      break
    }
    i += 1
  }

  white : sdl2.Color = {100, 200, 100, 255}
  active_window, ok_window_name := get_window_name(display, window_id).?
  win_icon_surface, ok_window_icon := get_window_icon(display, window_id).?

  if !ok_window_name {
    return nil
  }

  if active_window == "" || active_window == nil {
    return nil
  }

  font: ^ttf.Font
  get_matching_font(active_window, &font)
  if font == nil {
    fmt.panicf("Font was nil")
  }

  win_name_surface : ^sdl2.Surface = ttf.RenderUTF8_Solid(font, active_window, white)
  win_name_texture : ^sdl2.Texture = sdl2.CreateTextureFromSurface(renderer, win_name_surface)

  win_icon_texture : ^sdl2.Texture
  if ok_window_icon {
    win_icon_texture = sdl2.CreateTextureFromSurface(renderer, win_icon_surface)
  }
  else {
    win_icon_texture = nil
  }

  text_width, text_height : i32
  ttf.SizeUTF8(font, active_window, &text_width, &text_height)

  result := TextCache{win_name_surface, win_icon_surface, win_name_texture, win_icon_texture, window_id, text_width, text_height, true, font}

  if len(cache) > 100 {
    free_cache()
  }

  if found_existing_window >= 0 {
    cache[found_existing_window] = result
  }
  else {
    append(&cache, result)
  }

  return result
}

free_cache :: proc() {
  for &v in cache {
    sdl2.FreeSurface(v.surface)
    sdl2.DestroyTexture(v.texture)
    sdl2.FreeSurface(v.icon_surface)
    sdl2.DestroyTexture(v.icon_texture)
    if v.font != nil {
      ttf.CloseFont(v.font)
    }
    v.is_active = false
  }
  clear(&cache)
}

get_window_name :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(cstring) {
  props : xlib.XTextProperty
  active_window_atom := xlib.InternAtom(display, "_NET_WM_NAME", false)
  result := xlib.GetTextProperty(display, xid, &props, active_window_atom)
  if cast(i32)result == 0 { // Apparently this doesn't return the same type of Status as other functions?
    return nil
  }
  return cast(cstring)props.value
}

get_window_class :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(cstring) {
  hint_return : xlib.XClassHint
  result := xlib.GetClassHint(display, xid, &hint_return)

  if cast(i32)result == 0 {
    return nil
  }

  return hint_return.res_name
}

get_window_icon_from_file :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(^sdl2.Surface) {
  class_name, class_name_ok := get_window_class(display, xid).?
  if !class_name_ok {
    return nil
  }
  icon_surface, icon_ok := get_icon_from_class_name(class_name).?
  if !icon_ok {
    return nil
  }
  return icon_surface
}

get_icon_from_class_name :: proc(class_name: cstring) -> Maybe(^sdl2.Surface) {
  if class_name == "" {
    return nil
  }
  desktop_filepath := strings.concatenate({"/usr/share/applications/", strings.clone_from_cstring(class_name), ".desktop"})
	data, ok_desktop := os.read_entire_file(desktop_filepath, context.allocator)
	if !ok_desktop {
		return nil
	}
	defer delete(data, context.allocator)

	it := string(data)
  icon_name: string = ""
	for line in strings.split_lines_iterator(&it) {
    if strings.contains(line, "Icon") {
      head, match, tail := strings.partition(line, "=")
      icon_name = tail
    }
	}
  if icon_name == "" {
    return nil
  }

  icon_path := strings.concatenate({"/usr/share/icons/hicolor/128x128/apps/", strings.clone_from_cstring(class_name), ".png"})
  icon_rwops := sdl2.RWFromFile(strings.clone_to_cstring(icon_path), "rb")
  result := image.LoadPNG_RW(icon_rwops)
  return result
}

get_window_icon :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(^sdl2.Surface) {
  window_icon_surface, window_icon_ok := get_window_icon_from_file(display, xid).?
  if window_icon_ok {
    fmt.println("found png icon for ", get_window_class(display, xid), window_icon_surface)
    return window_icon_surface
  }
  else {
    fmt.println("couldn't find icon in png file", get_window_class(display, xid))
  }

  window_icon_atom := xlib.InternAtom(display, "_NET_WM_ICON", false)

  icon_size_type_return : xlib.Atom
  icon_size_format_return : i32
  icon_size_nitems_return, icon_size_bytes_left : uint = 0, 0
  icon_size_data : rawptr

  icon_data_type_return : xlib.Atom
  icon_data_format_return : i32
  icon_data_nitems_return, icon_data_bytes_left : uint = 0, 0
  icon_data_data : rawptr

  xlib.GetWindowProperty(display,
                         xid,
                         window_icon_atom,
                         0,
                         2,
                         false,
                         cast(xlib.Atom)6,
                         &icon_size_type_return,
                         &icon_size_format_return,
                         &icon_size_nitems_return,
                         &icon_size_bytes_left,
                         &icon_size_data)

  if icon_size_nitems_return != 2 {
    if icon_size_data != nil {
      xlib.Free(icon_size_data)
    }
    return nil
  }

  width := (cast(^int)icon_size_data)^
  height := (cast(^int)((cast(uintptr)icon_size_data) + size_of(int)))^

  if icon_size_data != nil {
    xlib.Free(icon_size_data)
  }

  pixel_data_size :int = width*height

  xlib.GetWindowProperty(display,
                         xid,
                         window_icon_atom,
                         2,
                         pixel_data_size,
                         false,
                         cast(xlib.Atom)6,
                         &icon_data_type_return,
                         &icon_data_format_return,
                         &icon_data_nitems_return,
                         &icon_data_bytes_left,
                         &icon_data_data)

  if icon_data_data == nil {
    return nil
  }

  if cast(i64)icon_data_bytes_left > 0 {
    return nil
  }

  iter_data := cast([^]u64)icon_data_data
  mask : u64 = 0x00000000000000FF
  image_buf : [dynamic]u8

  for i in 0..<icon_data_nitems_return { // lol it's not 32 even though xlib says it is
    r : u8 = cast(u8)(iter_data[i] & mask)
    g : u8 = cast(u8)((iter_data[i] >> 8) & mask)
    b : u8 = cast(u8)((iter_data[i] >> 16) & mask)
    a : u8 = cast(u8)((iter_data[i] >> 24) & mask)
    append(&image_buf, a)
    append(&image_buf, r)
    append(&image_buf, g)
    append(&image_buf, b)
  }

  if icon_data_data != nil {
    xlib.Free(icon_data_data)
  }

  surface := sdl2.CreateRGBSurfaceFrom(
    cast(rawptr)&image_buf[0],
    cast(i32)width,
    cast(i32)height,
    32,
    cast(i32)width * 4,
    0xFF000000,
    0x00FF0000,
    0x0000FF00,
    0x000000FF
  )

  return surface
}

get_active_window :: proc(display: ^xlib.Display) -> Maybe(xlib.XID) {
  property := xlib.InternAtom(display, "_NET_ACTIVE_WINDOW", false)

  type_return :xlib.Atom
  format_return :i32
  nitems_return, bytes_left :uint
  data :rawptr

  defer xlib.Free(data)

  root := xlib.DefaultRootWindow(display)

  result := xlib.GetWindowProperty(
              display,
              root,
              property,
              0,
              1,
              false,
              XA_WINDOW,
              &type_return,   // should be XA_WINDOW
              &format_return, // should be 32
              &nitems_return,
              &bytes_left,
              &data
          )

  if result != cast(i32)xlib.Status.Success {
    return nil
  }

  window_id := (cast(^xlib.XID)data)^
  if window_id == 0 {
    return nil
  }
  return window_id
}

get_matching_font :: proc(text: cstring, ttf_font: ^^ttf.Font) {
  pat := FcNameParse(cast(^c.char)preferred_font)
  charset := FcCharSetCreate()
  fc_result : FcResult

  ucs4: c.uint
  p: ^c.uchar = cast(^c.uchar)text

  for p^ != 0 {
    len : c.int = FcUtf8ToUcs4(p, &ucs4, cast(i32)libc.strlen(cast(cstring)p))
    if len <= 0 {
      break
    }
    FcCharSetAddChar(charset, ucs4)
    p = cast(^c.uchar)(cast(uintptr)(cast(i64)cast(uintptr)p + cast(i64)len))
  }

  FcPatternAddCharSet(pat, cast(^u8)strings.clone_to_cstring("charset"), charset)

  FcConfigSubstitute(nil, pat, FcMatchKind.FcMatchPattern)
  FcDefaultSubstitute(pat)
  fs := FcFontSetCreate()
  os := FcObjectSetBuild(cast(^u8)strings.clone_to_cstring("family"),
                         strings.clone_to_cstring("style"),
                         strings.clone_to_cstring("file"),
                         nil)

  font_patterns: ^FcFontSet = FcFontSort(nil, pat, 1, nil, &fc_result)

  if font_patterns == nil || font_patterns.nfont == 0 {
    fmt.panicf("No fonts configured on your system\n")
  }

  font_pattern: ^FcPattern = FcFontRenderPrepare(nil, pat, font_patterns.fonts^)

  if font_pattern != nil {
    FcFontSetAdd(fs, font_pattern)
  }
  else {
    fmt.panicf("Could not prepare matched font for loading\n")
  }

  if fs != nil {
    if fs.nfont > 0 {
      v: FcValue
      font: ^FcPattern = FcPatternFilter(fs.fonts^, os)
      FcPatternGet(font, cast(^u8)strings.clone_to_cstring("file"), 0, &v)
      if v.u.f != nil {
        found_font := cast(cstring)v.u.f
        ttf_font^ = ttf.OpenFont(found_font, 18)
        defer FcPatternDestroy(font)
      }
      defer FcFontSetDestroy(fs)
    }
  }
  else {
    fmt.panicf("No usable fonts on the system, check the font family")
  }

  if charset != nil {
    defer FcCharSetDestroy(charset)
  }
  if pat != nil {
    defer FcPatternDestroy(pat)
  }
  if font_patterns != nil {
    defer FcFontSetDestroy(font_patterns)
  }
  if os != nil {
    defer FcObjectSetDestroy(os)
  }
}

main :: proc() {
  display := xlib.OpenDisplay(nil)
  displayHeight := xlib.DisplayHeight(display, 0)
  displayWidth := xlib.DisplayWidth(display, 0)

  xlib.SetErrorHandler(handle_bad_window)
  xlib.SetIOErrorHandler(handle_io_error)

  defer xlib.CloseDisplay(display)
  screen := xlib.DefaultScreen(display)
  screen_width := xlib.DisplayWidth(display, screen)
  bar_height :u32 = 40

  // For expanding path to odinbar
  odinbar_wordexp :posix.wordexp_t
  odinbar_path :cstring = "~/.odinbar/odinbar"
  posix.wordexp(odinbar_path, &odinbar_wordexp, {})
  odinbar_path_expanded :cstring
  if odinbar_wordexp.we_wordc >= 1 {
    odinbar_path_expanded = cast(cstring)odinbar_wordexp.we_wordv[0]
  }
  else {
    odinbar_path_expanded = odinbar_path
  }

  root := xlib.RootWindow(display, screen)

  win :xlib.Window = xlib.CreateSimpleWindow(
      display, root,
      0, 0, // x, y
      cast(u32)screen_width, bar_height, // width, height
      0, // border width
      xlib.BlackPixel(display, screen),
      xlib.BlackPixel(display, screen)
  )
  net_wm_window_type := xlib.InternAtom(display, "_NET_WM_WINDOW_TYPE", false)
  net_wm_window_type_dock := xlib.InternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", false)
  xlib.ChangeProperty(
      display, win,
      net_wm_window_type,
      xlib.XA_ATOM, 32,
      xlib.PropModeReplace,
      &net_wm_window_type_dock,
      1
  )

  // Set _NET_WM_DESKTOP to 0xFFFFFFFF (all desktops)
  net_wm_desktop := xlib.InternAtom(display, "_NET_WM_DESKTOP", false)
  all_desktops :libc.long = 0xFFFFFFFF
  xlib.ChangeProperty(
      display, win,
      net_wm_desktop,
      XA_CARDINAL, 32,
      xlib.PropModeReplace,
      &all_desktops,
      1
  )


  // Set struts to reserve space (top bar, full width)
  net_wm_strut := xlib.InternAtom(display, "_NET_WM_STRUT", false)
  strut := [4]libc.long{0, 0, cast(i64)bar_height, 0} // left, right, top, bottom
  xlib.ChangeProperty(
      display, win,
      net_wm_strut,
      XA_CARDINAL, 32,
      xlib.PropModeReplace,
      &strut[0],
      4
  )

  net_wm_strut_partial := xlib.InternAtom(display, "_NET_WM_STRUT_PARTIAL", false)
  strut_partial := [12]libc.long{
      0, 0,                // left, right
      cast(i64)bar_height, 0,       // top, bottom
      0, 0,                // left_start_y, left_end_y
      0, 0,                // right_start_y, right_end_y
      0, cast(i64)screen_width,     // top_start_x, top_end_x
      0, 0                 // bottom_start_x, bottom_end_x
  }

  xlib.ChangeProperty(
      display, win,
      net_wm_strut_partial,
      XA_CARDINAL, 32,
      xlib.PropModeReplace,
      &strut_partial[0],
      12
  )

  // Select input events
  xlib.SelectInput(display, win, {xlib.EventMaskBits.Exposure})

  // Map window
  sdl_window := sdl2.CreateWindowFrom((cast(rawptr)cast(uintptr)win))
  xlib.MapWindow(display, win)
  xlib.Flush(display)

  renderer := sdl2.CreateRenderer(sdl_window, -1, {sdl2.RendererFlags.SOFTWARE})
  defer sdl2.DestroyRenderer(renderer)

  running : bool = true
  event : sdl2.Event

  ttf.Init()

  white : sdl2.Color = {255, 0, 0, 255}

  current_event : xlib.XEvent

  xlib.SelectInput(display,
                   root,
                   {xlib.EventMaskBits.PropertyChange,
                    xlib.EventMaskBits.SubstructureNotify,
                    xlib.EventMaskBits.KeyPress})

  xlib.GrabKey(display,
               cast(i32)xlib.KeysymToKeycode(display, xlib.KeySym.XK_V),
               {xlib.InputMaskBits.Mod1Mask},
               root,
               true,
               xlib.GrabMode.GrabModeAsync,
               xlib.GrabMode.GrabModeAsync)

  // Gets all currently active windows and adds them to the cache
  cache_active_windows(display, root, renderer)

  init_digits(renderer)
  sep_width := digit_cache.widths[100]

  tz, ok_tz := timezone.region_load("America/Toronto")

  if !ok_tz {
    fmt.panicf("Invalid timezone")
  }

  for running {
      for sdl2.PollEvent(&event) != false {
          if event.type == sdl2.EventType.QUIT {
              running = false
          }
      }

      if xlib.Pending(display) > 0 {
        xlib.NextEvent(display, &current_event)
        if (current_event.type == xlib.EventType.DestroyNotify) {
          for &v in cache {
            if v.is_active && v.window_id == current_event.xdestroywindow.window {
              fmt.println("Freeing window from cache")
              sdl2.FreeSurface(v.surface)
              sdl2.FreeSurface(v.icon_surface)
              sdl2.DestroyTexture(v.texture)
              sdl2.DestroyTexture(v.icon_texture)
              if v.font != nil {
                ttf.CloseFont(v.font)
              }
              v.is_active = false
            }
          }
        }
        if (current_event.type == xlib.EventType.MapNotify) {
          window_id := current_event.xmap.window
          if window_id != 0 {
            text_set_cached(display, renderer, window_id)

            fmt.println("======")
            for v in cache {
              if v.is_active {
                fmt.println(get_window_name(display, v.window_id))
              }
            }

            xlib.SelectInput(display,
                             window_id,
                             {xlib.EventMaskBits.PropertyChange,
                              xlib.EventMaskBits.StructureNotify,
                              xlib.EventMaskBits.SubstructureNotify})
          }
        }
        if (current_event.type == xlib.EventType.PropertyNotify) {
          if (current_event.xproperty.atom == xlib.InternAtom(display, "_NET_WM_NAME", false) ||
              current_event.xproperty.atom == xlib.InternAtom(display, "WM_NAME", false)) {
            window_id := current_event.xproperty.window
            if window_id != 0 {
              text_set_cached(display, renderer, window_id)
            }
          }
        }

        if current_event.type == xlib.EventType.KeyPress {
          if xlib.LookupKeysym(&current_event.xkey, 0) == xlib.KeySym.XK_v {
            libc.system("cd ~/.odinbar && echo 'rebuilding' && make debug")
            fmt.println(linux.execve(odinbar_path_expanded, nil, posix.environ))
          }
        }
      }

      sdl2.SetRenderDrawColor(renderer, 0, 0, 0, 255)
      sdl2.RenderClear(renderer)
      active_window, ok_window := get_active_window(display).?

      if ok_window {
        cached_texture, ok_text := text_get_cached(display, renderer, active_window).?

        if ok_text {
          rect : sdl2.Rect = {0, 0, cached_texture.text_width, cached_texture.text_height}
          icon_rect : sdl2.Rect = {cached_texture.text_width+10, 0, 32, 32}
          sdl2.RenderCopy(renderer, cached_texture.texture, nil, &rect)
          if cached_texture.icon_texture != nil {
            sdl2.RenderCopy(renderer, cached_texture.icon_texture, nil, &icon_rect)
          }
        }
        else {
          fmt.println("Failed to get any text to render!")
        }
      }

      t, ok_dt:= time.time_to_datetime(time.now())
      dt_with_tz := timezone.datetime_to_tz(t, tz)
      hour := dt_with_tz.hour
      minute := dt_with_tz.minute
      second := dt_with_tz.second

      clock_offset := screen_width - (digit_cache.widths[hour] + digit_cache.widths[minute] + digit_cache.widths[second] + sep_width*2)

      if hour >= 0 && hour <= 60 && minute >= 0 && minute <= 60 && second >= 0 && second <= 60 {
        num_rect_hour : sdl2.Rect = {clock_offset, 0, digit_cache.widths[hour], digit_cache.heights[hour]}
        num_rect_hour_sep : sdl2.Rect = {clock_offset + digit_cache.widths[hour], 0, digit_cache.widths[100], digit_cache.heights[100]}
        num_rect_minute : sdl2.Rect = {clock_offset + digit_cache.widths[hour] + sep_width, 0, digit_cache.widths[minute], digit_cache.heights[minute]}
        num_rect_minute_sep : sdl2.Rect = {clock_offset + digit_cache.widths[hour] + digit_cache.widths[minute] + sep_width, 0, digit_cache.widths[100], digit_cache.heights[100]}
        num_rect_second : sdl2.Rect = {clock_offset + digit_cache.widths[minute] + digit_cache.widths[hour] + sep_width*2, 0, digit_cache.widths[second], digit_cache.heights[second]}

        sdl2.RenderCopy(renderer, digit_cache.textures[hour], nil, &num_rect_hour)
        sdl2.RenderCopy(renderer, digit_cache.textures[100], nil, &num_rect_hour_sep)
        sdl2.RenderCopy(renderer, digit_cache.textures[minute], nil, &num_rect_minute)
        sdl2.RenderCopy(renderer, digit_cache.textures[100], nil, &num_rect_minute_sep)
        sdl2.RenderCopy(renderer, digit_cache.textures[second], nil, &num_rect_second)
      }
      sdl2.RenderPresent(renderer)
      sdl2.Delay(8)
  }
}
