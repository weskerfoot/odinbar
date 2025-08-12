package main
import "core:c/libc"
import "core:fmt"
import "core:strings"
import "core:mem"
import "core:os"
import "core:time"
import "vendor:sdl2"
import "vendor:sdl2/ttf"
import "vendor:x11/xlib"

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
                             renderer: ^sdl2.Renderer,
                             font: ^ttf.Font) {
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
      text_set_cached(display, renderer, font, current_window)
    }
  }
}


XA_CARDINAL : xlib.Atom = 6
XA_WINDOW : xlib.Atom = 33

TextCacheItem :: struct {
  surface: ^sdl2.Surface,
  texture: ^sdl2.Texture,
  window_id: xlib.XID,
  text_width: i32,
  text_height: i32,
  is_active: bool
}

cache: #soa[dynamic]TextCacheItem

text_get_cached :: proc(display: ^xlib.Display,
                        renderer: ^sdl2.Renderer,
                        font: ^ttf.Font,
                        window_id: xlib.XID) -> Maybe(TextCacheItem) {
  if window_id == 0 {
    return nil
  }
  for v in cache {
    if v.window_id == window_id {
      return v
    }
  }
  return text_set_cached(display, renderer, font, window_id)
}

text_set_cached :: proc(display: ^xlib.Display,
                        renderer: ^sdl2.Renderer,
                        font: ^ttf.Font,
                        window_id: xlib.XID) -> Maybe(TextCacheItem) {

  if window_id == 0 {
    return nil
  }

  // If it's already in there find it and free the existing texture/surface first
  found_existing_window := -1
  i := 0
  for &v in cache {
    if v.window_id == window_id {
      sdl2.FreeSurface(v.surface)
      sdl2.DestroyTexture(v.texture)
      found_existing_window = i
      v.is_active = false
      break
    }
    i += 1
  }

  white : sdl2.Color = {255, 255, 255, 255}
  active_window, ok_window_name := get_window_name(display, window_id).?

  if !ok_window_name {
    return nil
  }

  win_name_surface : ^sdl2.Surface = ttf.RenderUTF8_Solid(font, active_window, white)
  win_name_texture : ^sdl2.Texture = sdl2.CreateTextureFromSurface(renderer, win_name_surface)

  text_width, text_height : i32
  ttf.SizeUTF8(font, active_window, &text_width, &text_height)

  result := TextCacheItem{win_name_surface, win_name_texture, window_id, text_width, text_height, true}
  if len(cache) > 50 {
    free_cache()
  }

  if found_existing_window >= 0 {
    cache[i] = result
  }
  else {
    append(&cache, result)
  }
  return result
}

free_cache :: proc() {
  for v in cache {
    sdl2.FreeSurface(v.surface)
    sdl2.DestroyTexture(v.texture)
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

get_active_window :: proc(display: ^xlib.Display) -> Maybe(xlib.XID) {
  property := xlib.InternAtom(display, "_NET_ACTIVE_WINDOW", false)

  type_return :xlib.Atom
  format_return :i32
  nitems_return :uint
  bytes_left :uint
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

  return (cast(^xlib.XID)data)^
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

  root := xlib.RootWindow(display, screen)

  win :xlib.Window = xlib.CreateSimpleWindow(
      display, root,
      0, 0,                       // x, y
      cast(u32)screen_width, bar_height,  // width, height
      0,                          // border width
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

  renderer := sdl2.CreateRenderer(sdl_window, -1, {sdl2.RendererFlags.SOFTWARE});
  defer sdl2.DestroyRenderer(renderer);

  running : bool = true
  event : sdl2.Event

  ttf.Init()

  white : sdl2.Color = {255, 255, 255, 255}
  sans : ^ttf.Font = ttf.OpenFont("/usr/share/fonts/ubuntu/UbuntuMono-R.ttf", 24)

  assert (sans != nil)

  defer ttf.Quit()
  defer free_cache()

  current_event : xlib.XEvent

  xlib.SelectInput(display,
                   root,
                   {xlib.EventMaskBits.PropertyChange,
                    xlib.EventMaskBits.SubstructureNotify})

  // Gets all currently active windows and adds them to the cache
  cache_active_windows(display, root, renderer, sans)

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
              v.is_active = false
            }
          }
        }
        if (current_event.type == xlib.EventType.MapNotify) {
          window_id := current_event.xmap.window
          if window_id != 0 {
            text_set_cached(display, renderer, sans, window_id)

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
            text_set_cached(display, renderer, sans, current_event.xproperty.window)
          }
        }
      }

      sdl2.SetRenderDrawColor(renderer, 255, 0, 0, 255)
      sdl2.RenderClear(renderer)
      active_window, ok_window := get_active_window(display).?

      if ok_window {
        cached_texture, ok_text := text_get_cached(display, renderer, sans, active_window).?
        rect : sdl2.Rect = {0, 0, cached_texture.text_width, cached_texture.text_height}
        if ok_text {
          sdl2.RenderCopy(renderer, cached_texture.texture, nil, &rect)
        }

        sdl2.RenderPresent(renderer)
      }
      sdl2.Delay(8)
  }
}
