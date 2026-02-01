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

icon_size :i32 = 32 // Note that it loads 32x32 icons by default so this matches that
preferred_font: cstring = "Noto Sans"

RenderCache :: struct {
  surface: ^sdl2.Surface,
  texture: ^sdl2.Texture
}

// Convenience struct for procs that can return an icon
// this stuff along with the texture is stored in IconCache
SDLIcon :: struct {
  surface: ^sdl2.Surface,
  image_buf: [dynamic]u8, // underlying buffer if not nil
  rwops: ^sdl2.RWops // possibly nil
}

IconCache :: struct {
  surface: ^sdl2.Surface,
  texture: ^sdl2.Texture,
  rwops: ^sdl2.RWops,
  image_buf: [dynamic]u8 // underlying buffer if not nil
}

TextCache :: struct {
  window_status_cache: RenderCache,
  icon_status_cache: IconCache,
  window_selector_cache: RenderCache,
  window_name: string,
  window_id: xlib.XID,
  text_width: i32,
  text_height: i32,
  is_active: bool,
  font: ^ttf.Font
}

get_max_width :: proc() -> i32 {
  total :i32 = 0
  for v in &cache {
    if v.is_active {
      total = max(total, v.text_width)
    }
  }
  return total + 100
}

get_max_height :: proc() -> i32 {
  max_height :i32 = 0
  count_active :i32 = 0
  for v in &cache {
    if v.is_active {
      max_height = max(max_height, v.text_height)
      count_active += 1
    }
  }
  return (max_height + 10) * count_active
}

cache: #soa[dynamic]TextCache

FontCache :: struct {
  font_path: string,
  font: ^ttf.Font
}

font_cache: #soa[dynamic]FontCache

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
  get_matching_font("abc123", 7, &font)
  if font == nil {
    fmt.panicf("Got a nil font in init_digits")
  }

  text_width, text_height : i32
  c :[]u8 = {0, 0}
  num_st : cstring
  padded :[2]string
  padded[0] = "0"
  for i in 0..<10 {
    padded[1] = strconv.itoa(c, i)
    concatenated := strings.concatenate(padded[:])
    defer delete(concatenated)
    num_st = strings.clone_to_cstring(concatenated)
    defer delete(num_st)
    ttf.SizeUTF8(font, num_st, &text_width, &text_height)
    digit_cache.surfaces[i] = ttf.RenderUTF8_Solid(font, num_st, white)
    digit_cache.textures[i] = sdl2.CreateTextureFromSurface(renderer, digit_cache.surfaces[i])
    digit_cache.widths[i] = text_width
    digit_cache.heights[i] = text_height
  }
  for i in 10..<100 {
    num_st = strings.clone_to_cstring(strconv.itoa(c, i))
    defer delete(num_st)
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

text_get_cached :: proc(display: ^xlib.Display,
                        renderer: ^sdl2.Renderer,
                        selector_renderer: ^sdl2.Renderer,
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
  return text_set_cached(display, renderer, selector_renderer, window_id)
}

text_set_cached :: proc(display: ^xlib.Display,
                        renderer: ^sdl2.Renderer,
                        selector_renderer: ^sdl2.Renderer,
                        window_id: xlib.XID) -> Maybe(TextCache) {

  if window_id == 0 {
    fmt.println("got window_id == 0 in text_set_cached")
    return nil
  }
  if len(cache) > 250 {
    free_cache()
  }

  // If it's already in there find it and free the existing texture/surface first
  found_existing_window := -1
  i := 0
  for &v in cache {
    if v.window_id == window_id && v.is_active {
      found_existing_window = i
      sdl2.FreeSurface(v.window_status_cache.surface)
      sdl2.DestroyTexture(v.window_status_cache.texture)
      sdl2.FreeSurface(v.icon_status_cache.surface)
      sdl2.DestroyTexture(v.icon_status_cache.texture)
      sdl2.FreeSurface(v.window_selector_cache.surface)
      sdl2.DestroyTexture(v.window_selector_cache.texture)
      delete(v.window_name)
      if v.icon_status_cache.rwops != nil {
        sdl2.FreeRW(v.icon_status_cache.rwops)
      }
      if v.icon_status_cache.image_buf != nil {
        delete(v.icon_status_cache.image_buf)
      }
      v.is_active = false
      break
    }
    i += 1
  }

  white : sdl2.Color = {100, 200, 100, 255}
  window_text_props, ok_window_props := get_window_name(display, window_id).?
  win_icon, ok_window_icon := get_window_icon(display, window_id).?

  defer xlib.Free(window_text_props.value)

  if !ok_window_props {
    return nil
  }

  active_window := cast(cstring)window_text_props.value

  if active_window == "" || active_window == nil {
    return nil
  }

  font: ^ttf.Font
  window_name_len := cast(i32)libc.strlen(cast(cstring)active_window)
  bytes_processed, bytes_processed_ok := get_matching_font(active_window, window_name_len, &font).?
  if bytes_processed != window_name_len {
    fmt.println("Couldn't match entire string to font!")
    fmt.println(window_name_len, bytes_processed)
  }
  if font == nil {
    fmt.panicf("Font was nil")
  }

  win_name_surface : ^sdl2.Surface = ttf.RenderUTF8_Solid(font, active_window, white)
  win_name_texture : ^sdl2.Texture = sdl2.CreateTextureFromSurface(renderer, win_name_surface)

  win_name_select_surface : ^sdl2.Surface = ttf.RenderUTF8_Solid(font, active_window, white)
  win_name_select_texture : ^sdl2.Texture = sdl2.CreateTextureFromSurface(selector_renderer, win_name_surface)

  win_icon_texture : ^sdl2.Texture
  if ok_window_icon {
    win_icon_texture = sdl2.CreateTextureFromSurface(renderer, win_icon.surface)
  }
  else {
    win_icon_texture = nil
  }

  text_width, text_height : i32
  ttf.SizeUTF8(font, active_window, &text_width, &text_height)

  result := TextCache{RenderCache{win_name_surface, win_name_texture},
                      IconCache{win_icon.surface, win_icon_texture, win_icon.rwops, win_icon.image_buf},
                      RenderCache{win_name_select_surface, win_name_select_texture},
                      strings.clone_from_cstring(active_window),
                      window_id,
                      text_width,
                      text_height,
                      true,
                      font}

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
    if v.is_active {
      // TODO make separate proc to free RenderCache structs
      sdl2.FreeSurface(v.window_status_cache.surface)
      sdl2.DestroyTexture(v.window_status_cache.texture)
      sdl2.FreeSurface(v.icon_status_cache.surface)
      sdl2.DestroyTexture(v.icon_status_cache.texture)
      sdl2.FreeSurface(v.window_selector_cache.surface)
      sdl2.DestroyTexture(v.window_selector_cache.texture)
      delete(v.window_name)
      if v.icon_status_cache.rwops != nil {
        sdl2.FreeRW(v.icon_status_cache.rwops)
      }
      if v.icon_status_cache.image_buf != nil {
        delete(v.icon_status_cache.image_buf)
      }
      v.is_active = false
    }
  }
  clear(&cache)
}

cache_active_windows :: proc(display: ^xlib.Display,
                             root_window: xlib.XID,
                             renderer: ^sdl2.Renderer,
                             selector_renderer: ^sdl2.Renderer) {
  root := xlib.DefaultRootWindow(display)

  net_client_list_atom := xlib.InternAtom(display, "_NET_CLIENT_LIST", false)

  size_type_return : xlib.Atom
  size_format_return : i32
  size_nitems_return, bytes_left : uint = 0, 0
  size_data : rawptr

  type_return : xlib.Atom
  format_return : i32
  nitems_return, icon_data_bytes_left : uint = 0, 0
  data : rawptr

  result := xlib.GetWindowProperty(
        display,
        root,
        net_client_list_atom,
        0,
        -1,
        false,
        XA_WINDOW,
        &type_return,
        &format_return,
        &nitems_return,
        &bytes_left,
        &data
    )
  if result != cast(i32)xlib.Status.Success {
    fmt.println("Could not access EWMH property _NET_CLIENT_LIST, can't get active windows")
    return
  }
  windows := cast([^]xlib.XID)data
  defer xlib.Free(data)

  for i in 0..<nitems_return { // lol it's not 32 even though xlib says it is
    window_text_props, text_props_ok := get_window_name(display, windows[i]).?
    defer xlib.Free(window_text_props.value)
    if text_props_ok {
      fmt.println(cast(cstring)window_text_props.value)
      text_set_cached(display, renderer, selector_renderer, windows[i])
    }
  }
}

get_window_name :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(xlib.XTextProperty) {
  props : xlib.XTextProperty
  active_window_atom := xlib.InternAtom(display, "_NET_WM_NAME", false)
  result := xlib.GetTextProperty(display, xid, &props, active_window_atom)
  if cast(i32)result == 0 { // Apparently this doesn't return the same type of Status as other functions?
    return nil
  }
  return props
}

get_window_class :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(xlib.XClassHint) {
  hint_return : xlib.XClassHint
  result := xlib.GetClassHint(display, xid, &hint_return)

  if cast(i32)result == 0 {
    return nil
  }

  return hint_return
}

get_window_icon_from_file :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(SDLIcon) {
  hint_return, class_name_ok := get_window_class(display, xid).?
  defer xlib.Free(cast(rawptr)hint_return.res_name)
  defer xlib.Free(cast(rawptr)hint_return.res_class)
  if !class_name_ok {
    return nil
  }
  icon_from_name, icon_from_name_ok := get_icon_from_class_name(hint_return.res_name).?
  icon_from_class, icon_from_class_ok := get_icon_from_class_name(hint_return.res_class).?
  if icon_from_name_ok && icon_from_name.surface != nil {
    return icon_from_name
  }
  if icon_from_class_ok && icon_from_class.surface != nil {
    return icon_from_class
  }
  return nil
}

get_icon_from_class_name :: proc(class_name: cstring) -> Maybe(SDLIcon) {
  if class_name == "" {
    return nil
  }
  class_name_st := strings.clone_from_cstring(class_name)
  desktop_filepath := strings.concatenate({"/usr/share/applications/", class_name_st, ".desktop"})
  defer delete(class_name_st)
  defer delete(desktop_filepath)
	data, ok_desktop := os.read_entire_file(desktop_filepath)
	defer delete(data)

	if !ok_desktop {
		return nil
	}

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

  icon_path_hicolor := strings.concatenate({"/usr/share/icons/hicolor/32x32/apps/", class_name_st, ".png"})
  icon_path_locolor := strings.concatenate({"/usr/share/icons/locolor/32x32/apps/", class_name_st, ".png"})

  icon_path_cst :cstring
  if os.is_file(icon_path_hicolor) {
    icon_path_cst = strings.clone_to_cstring(icon_path_hicolor)
  }
  else {
    icon_path_cst = strings.clone_to_cstring(icon_path_locolor)
  }
  defer delete(icon_path_cst)
  defer delete(icon_path_hicolor)
  defer delete(icon_path_locolor)
  icon_rwops := sdl2.RWFromFile(icon_path_cst, "rb")
  result := image.LoadPNG_RW(icon_rwops)
  return SDLIcon{result, nil, icon_rwops}
}

get_window_icon :: proc(display: ^xlib.Display, xid: xlib.XID) -> Maybe(SDLIcon) {
  window_icon, window_icon_ok := get_window_icon_from_file(display, xid).?
  if window_icon_ok && window_icon.surface != nil {
    return window_icon
  }
  else {
    fmt.println("couldn't find icon in png file")
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

  return SDLIcon{surface, image_buf, nil}
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

charset_cst : cstring = "charset"
family_cst : cstring = "family"
style_cst : cstring = "style"
file_cst : cstring = "file"

get_emoji_font :: proc(text: cstring, offset: i64, window_len: i32, ttf_font: ^^ttf.Font) -> Maybe(i32) {
  p: ^c.uchar = cast(^c.uchar)text
  p = cast(^c.uchar)(cast(uintptr)(cast(i64)cast(uintptr)p + offset))
  text_len := window_len

  ucs4: c.uint
  pat := FcNameParse(cast(^c.char)preferred_font)
  charset := FcCharSetCreate()
  defer FcCharSetDestroy(charset)
  fc_result : FcResult

  for p^ != 0 {
    char_len : c.int = FcUtf8ToUcs4(p, &ucs4, text_len)
    if char_len <= 0 {
      break
    }
    FcCharSetAddChar(charset, ucs4)
    text_len -= char_len
    p = cast(^c.uchar)(cast(uintptr)(cast(i64)cast(uintptr)p + cast(i64)char_len))
  }

  FcPatternAddCharSet(pat, cast(^u8)charset_cst, charset)

  FcConfigSubstitute(nil, pat, FcMatchKind.FcMatchPattern)
  FcDefaultSubstitute(pat)
  defer if pat != nil { FcPatternDestroy(pat) }
  fs := FcFontSetCreate()
  defer if fs != nil { FcFontSetDestroy(fs) }

  os := FcObjectSetBuild(cast(^u8)family_cst,
                         style_cst,
                         file_cst,
                         nil)

  defer if os != nil { FcObjectSetDestroy(os) }
  font_patterns: ^FcFontSet = FcFontSort(nil, pat, 1, nil, &fc_result)
  fonts_to_check : [^]^FcPattern = font_patterns.fonts

  // This loop leaks a lot of memory!
  for i in 0..<font_patterns.nfont {
    font_pat := FcFontRenderPrepare(nil, pat, fonts_to_check[i])
    v: FcValue
    font: ^FcPattern = FcPatternFilter(font_pat, os)
    FcPatternGet(font, cast(^u8)file_cst, 0, &v)
    found_font := cast(cstring)v.u.f
    fmt.println(found_font)
  }

  defer if font_patterns != nil { FcFontSetDestroy(font_patterns) }
  return 0
}

check_text_renders :: proc(text: cstring, ttf_font: ^ttf.Font) -> i32 {
  ucs4: c.uint
  p: ^c.uchar = cast(^c.uchar)text

  font_renders := true

  text_len := cast(i32)libc.strlen(cast(cstring)p)
  bytes_processed :i32 = 0

  for p^ != 0 {
    char_len : c.int = FcUtf8ToUcs4(p, &ucs4, text_len)
    bytes_processed += char_len
    if char_len <= 0 {
      break
    }
    if ttf.GlyphIsProvided32(ttf_font, cast(rune)ucs4) == 0 {
      break
    }
    text_len -= char_len
    // Yes this is ugly, there might be a nicer way with multi-pointers
    p = cast(^c.uchar)(cast(uintptr)(cast(i64)cast(uintptr)p + cast(i64)char_len))
  }
  return bytes_processed
}

get_matching_font :: proc(text: cstring, window_len: i32, ttf_font: ^^ttf.Font) -> Maybe(i32) {
  p: ^c.uchar = cast(^c.uchar)text
  text_len := window_len

  // Early check to see if the text can be rendered by any cached fonts
  for f in font_cache {
    bytes_processed := check_text_renders(text, f.font)
    if bytes_processed == text_len {
      fmt.println("found matching font before running get_matching_font")
      ttf_font^ = f.font
      return bytes_processed
    }
    else {
      fmt.println("didn't find a font that matched all characters before actually using fc")
    }
  }

  ucs4: c.uint
  pat := FcNameParse(cast(^c.char)preferred_font)
  charset := FcCharSetCreate()
  defer FcCharSetDestroy(charset)
  fc_result : FcResult

  for p^ != 0 {
    char_len : c.int = FcUtf8ToUcs4(p, &ucs4, text_len)
    if char_len <= 0 {
      break
    }
    FcCharSetAddChar(charset, ucs4)
    text_len -= char_len
    p = cast(^c.uchar)(cast(uintptr)(cast(i64)cast(uintptr)p + cast(i64)char_len))
  }

  FcPatternAddCharSet(pat, cast(^u8)charset_cst, charset)

  FcConfigSubstitute(nil, pat, FcMatchKind.FcMatchPattern)
  FcDefaultSubstitute(pat)
  defer if pat != nil { FcPatternDestroy(pat) }
  fs := FcFontSetCreate()
  defer if fs != nil { FcFontSetDestroy(fs) }

  os := FcObjectSetBuild(cast(^u8)family_cst,
                         style_cst,
                         file_cst,
                         nil)

  defer if os != nil { FcObjectSetDestroy(os) }
  font_patterns: ^FcFontSet = FcFontSort(nil, pat, 1, nil, &fc_result)
  fonts_to_check : [^]^FcPattern = font_patterns.fonts
  defer if font_patterns != nil { FcFontSetDestroy(font_patterns) }

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
      FcPatternGet(font, cast(^u8)file_cst, 0, &v)
      if v.u.f != nil {
        found_font := cast(cstring)v.u.f
        found_font_st := strings.clone_from_cstring(found_font)
        found_font_cached : bool = false
        for f in font_cache {
          if f.font_path == found_font_st {
            ttf_font^ = f.font
            found_font_cached = true
            fmt.println("font cache hit")
            break
          }
        }
        if !found_font_cached {
          fmt.println("font cache miss")
          ttf_font^ = ttf.OpenFont(found_font, 18)
          append(&font_cache, FontCache{found_font_st, ttf_font^})
        }
        else {
          delete(found_font_st)
        }
        FcPatternDestroy(font)
      }
    }
  }
  else {
    fmt.panicf("No usable fonts on the system, check the font family")
  }
  if ttf_font^ != nil {
    return check_text_renders(text, ttf_font^)
  }
  return nil
}

set_window_props :: proc(win: xlib.Window,
                         win_height: i64,
                         win_width: i64,
                         display: ^xlib.Display,
                         set_struts: bool) {
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

  if set_struts {
    // Set struts to reserve space (top bar, full width)
    net_wm_strut := xlib.InternAtom(display, "_NET_WM_STRUT", false)
    strut := [4]libc.long{0, 0, win_height, 0} // left, right, top, bottom
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
        win_height, 0,       // top, bottom
        0, 0,                // left_start_y, left_end_y
        0, 0,                // right_start_y, right_end_y
        0, win_width,     // top_start_x, top_end_x
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
  defer posix.wordfree(&odinbar_wordexp)

  root := xlib.RootWindow(display, screen)

  win :xlib.Window = xlib.CreateSimpleWindow(
      display, root,
      0, 0, // x, y
      cast(u32)screen_width, bar_height, // width, height
      0, // border width
      xlib.BlackPixel(display, screen),
      xlib.BlackPixel(display, screen)
  )

  // window selector
  selector_win := xlib.CreateSimpleWindow(
    display, root,
    0, cast(i32)bar_height, // x, y
    cast(u32)300, 300, // width, height
    2, // border width
    xlib.BlackPixel(display, screen),
    xlib.BlackPixel(display, screen)
  )

  set_window_props(win, cast(i64)bar_height, cast(i64)screen_width, display, true)

  // Select input events
  xlib.SelectInput(display, win, {xlib.EventMaskBits.Exposure})

  // Map window
  sdl_window := sdl2.CreateWindowFrom((cast(rawptr)cast(uintptr)win))
  sdl_selector_win := sdl2.CreateWindowFrom((cast(rawptr)cast(uintptr)selector_win))
  set_window_props(selector_win, 300, 300, display, false)
  xlib.MapWindow(display, win)
  xlib.Flush(display)

  renderer := sdl2.CreateRenderer(sdl_window, -1, {sdl2.RendererFlags.ACCELERATED})
  defer sdl2.DestroyRenderer(renderer)

  selector_renderer := sdl2.CreateRenderer(sdl_selector_win, -1, {sdl2.RendererFlags.ACCELERATED})
  defer sdl2.DestroyRenderer(selector_renderer)

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
  cache_active_windows(display, root, renderer, selector_renderer)

  init_digits(renderer)
  sep_width := digit_cache.widths[100]

  tz, ok_tz := timezone.region_load("America/Toronto")
  defer timezone.region_destroy(tz)

  if !ok_tz {
    fmt.panicf("Invalid timezone")
  }

  selector_showing :bool = false

  for running {
      for sdl2.PollEvent(&event) != false {
          if event.type == sdl2.EventType.QUIT {
              running = false
          }
          else if event.type == sdl2.EventType.MOUSEBUTTONDOWN {
            fmt.println("button down")
            fmt.println(event)
            if !selector_showing {
              selector_showing = true
              xlib.MapWindow(display, selector_win)
              sdl2.SetWindowSize(sdl_selector_win, get_max_width(), get_max_height())
            }
            else {
              xlib.UnmapWindow(display, selector_win)
              selector_showing = false
            }
          }
          else if event.type == sdl2.EventType.MOUSEBUTTONUP {
            fmt.println("button up")
            fmt.println(event)
          }
      }

      for xlib.Pending(display) > 0 {
        xlib.NextEvent(display, &current_event)
        if (current_event.type == xlib.EventType.DestroyNotify) {
          for &v in cache {
            if v.is_active && v.window_id == current_event.xdestroywindow.window {
              // TODO, function for just free-ing one TextCache record
              fmt.println("Freeing window from cache")
              sdl2.FreeSurface(v.window_status_cache.surface)
              sdl2.FreeSurface(v.icon_status_cache.surface)
              sdl2.FreeSurface(v.window_selector_cache.surface)
              sdl2.DestroyTexture(v.window_status_cache.texture)
              sdl2.DestroyTexture(v.icon_status_cache.texture)
              sdl2.DestroyTexture(v.window_selector_cache.texture)
              delete(v.window_name)
              if v.icon_status_cache.rwops != nil {
                sdl2.FreeRW(v.icon_status_cache.rwops)
              }
              if v.icon_status_cache.image_buf != nil {
                delete(v.icon_status_cache.image_buf)
              }
              v.is_active = false
            }
          }
        }
        if (current_event.type == xlib.EventType.MapNotify) {
          window_id := current_event.xmap.window
          root_ret : xlib.XID
          parent_ret : xlib.XID
          children_ret : [^]xlib.XID // array of pointers to windows
          n_children_ret : u32
          xlib.QueryTree(display, window_id, &root_ret, &parent_ret, &children_ret, &n_children_ret)
          defer xlib.Free(children_ret)


          if selector_showing {
            sdl2.SetWindowSize(sdl_selector_win, get_max_width(), get_max_height())
          }
          attrs, attrs_ok := get_attributes(display, window_id).?
          if window_id != 0 { // FIXME check override_redirect instead?
            if attrs_ok {
              if attrs.override_redirect == false {
                text_set_cached(display, renderer, selector_renderer, window_id)
                xlib.SelectInput(display,
                                 window_id,
                                 {xlib.EventMaskBits.PropertyChange,
                                  xlib.EventMaskBits.StructureNotify,
                                  xlib.EventMaskBits.SubstructureNotify,})
              }
            }
          }
        }
        if (current_event.type == xlib.EventType.PropertyNotify) {
          if (current_event.xproperty.atom == xlib.InternAtom(display, "_NET_WM_NAME", false) ||
              current_event.xproperty.atom == xlib.InternAtom(display, "WM_NAME", false)) {
            window_id := current_event.xproperty.window
            attrs, attrs_ok := get_attributes(display, window_id).?
            if window_id != 0 {
              if selector_showing {
                sdl2.SetWindowSize(sdl_selector_win, get_max_width(), get_max_height())
              }
              if attrs_ok && attrs.override_redirect == false {
                text_set_cached(display, renderer, selector_renderer, window_id)
              }
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

      if selector_showing {
        offset :i32 = 0
        sdl2.SetRenderDrawColor(selector_renderer, 23, 0, 60, 255)
        sdl2.RenderClear(selector_renderer)
        for v in &cache {
          if v.is_active {
            rect : sdl2.Rect = {0, offset, v.text_width, v.text_height}
            sdl2.RenderCopy(selector_renderer, v.window_selector_cache.texture, nil, &rect)
            offset += v.text_height
          }
        }
        sdl2.RenderPresent(selector_renderer)
      }

      sdl2.SetRenderDrawColor(renderer, 0, 0, 0, 255)
      sdl2.RenderClear(renderer)
      active_window, ok_window := get_active_window(display).?
      offset :i32 = 0

      // Show other icons
      for v in &cache {
        if v.is_active && v.icon_status_cache.texture != nil && v.window_id != active_window {
          icon_rect : sdl2.Rect = {offset, 0, icon_size, icon_size}
          sdl2.RenderCopy(renderer, v.icon_status_cache.texture, nil, &icon_rect)
          offset += icon_size
        }
      }

      if ok_window {
        active_cached_texture, active_ok := text_get_cached(display, renderer, selector_renderer, active_window).?
        if active_ok && active_cached_texture.icon_status_cache.texture != nil {
          rect : sdl2.Rect = {offset+icon_size, 5, active_cached_texture.text_width, active_cached_texture.text_height}
          icon_rect : sdl2.Rect = {offset, 0, icon_size, icon_size}
          sdl2.RenderCopy(renderer, active_cached_texture.window_status_cache.texture, nil, &rect)
          sdl2.RenderCopy(renderer, active_cached_texture.icon_status_cache.texture, nil, &icon_rect)
        }
        else if active_ok {
          rect : sdl2.Rect = {offset, 5, active_cached_texture.text_width, active_cached_texture.text_height}
          sdl2.RenderCopy(renderer, active_cached_texture.window_status_cache.texture, nil, &rect)
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
