package main
import "core:c/libc"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import "vendor:raylib"
import "vendor:x11/xlib"

main :: proc() {
  display := xlib.OpenDisplay(nil)
  displayHeight := xlib.DisplayHeight(display, 0)
  displayWidth := xlib.DisplayWidth(display, 0)

  defer xlib.CloseDisplay(display)

  net_wm_window_type : xlib.Atom = xlib.InternAtom(display, "_NET_WM_WINDOW_TYPE", false)
  net_wm_window_type_dock : xlib.Atom = xlib.InternAtom(display, "_NET_WM_WINDOW_TYPE_DOCK", false)

  raylib.InitWindow(displayWidth*3, 50, "Odinbar")

  rootWindow := xlib.DefaultRootWindow(display)
  net_client_list_atom := xlib.InternAtom(display, "_NET_CLIENT_LIST", false)

  actual_type: xlib.Atom
  actual_format :i32
  nitems :uint
  bytes_after :uint
  prop_return: rawptr
  XA_WINDOW : xlib.Atom = cast(xlib.Atom)33

  long_length := 0

  xlib.GetWindowProperty(display, rootWindow, net_client_list_atom, 0, ~long_length, false,
                         XA_WINDOW, &actual_type, &actual_format, &nitems,
                         &bytes_after, &prop_return)

  assert (prop_return != nil)

  window_name : cstring

  my_window : xlib.XID

  if (prop_return != nil && actual_type == XA_WINDOW) {
    fmt.println("I can get the windows")
    windows := cast(^xlib.Window)prop_return
    i : uint = 0
    for (i < nitems) {
      window_id := mem.ptr_offset(windows, i)
      i += 1
      xlib.FetchName(display, window_id^, &window_name)
      if window_name == "Odinbar" {
        fmt.println("Got em", window_id^)
        my_window = window_id^
      }
      xlib.Free(cast(rawptr)window_name)
    }
    xlib.Free(prop_return)
  }

  strut := [12]libc.long{0, 0, 20, 0,
                         0, 0,
                         0, 0,
                         0, 1919,
                         0, 0}

  xlib.UnmapWindow(display, my_window)

  xlib.ChangeProperty(display, my_window, net_wm_window_type, xlib.XA_ATOM, 32,
                      xlib.PropModeReplace, cast(rawptr)&net_wm_window_type_dock, 1)


  XA_CARDINAL : xlib.Atom = 6


  net_wm_strut_partial : xlib.Atom = xlib.InternAtom(display, "_NET_WM_STRUT_PARTIAL", false);
  net_wm_strut : xlib.Atom = xlib.InternAtom(display, "_NET_WM_STRUT", false);

  xlib.ChangeProperty(display, my_window, net_wm_strut_partial, XA_CARDINAL, 32,
                  xlib.PropModeReplace, cast(^libc.uchar)&strut[0], 12)

  xlib.ChangeProperty(display, my_window, net_wm_strut, XA_CARDINAL, 32,
                  xlib.PropModeReplace, cast(^libc.uchar)&strut[0], 4)


  attr : xlib.XWindowAttributes
  attr.override_redirect = false
  xlib.ChangeWindowAttributes(display, my_window, {.CWOverrideRedirect}, &attr);

  xlib.MoveResizeWindow(display, my_window, 0, 0, 1920, 20);  // top bar, 1920x20
  xlib.MapWindow(display, my_window)

  for !raylib.WindowShouldClose() {
    raylib.BeginDrawing()
    xlib.ChangeProperty(display, my_window, net_wm_window_type, xlib.XA_ATOM, 32,
                        xlib.PropModeReplace, cast(rawptr)&net_wm_window_type_dock, 1)


    XA_CARDINAL : xlib.Atom = 6


    net_wm_strut_partial : xlib.Atom = xlib.InternAtom(display, "_NET_WM_STRUT_PARTIAL", false);
    net_wm_strut : xlib.Atom = xlib.InternAtom(display, "_NET_WM_STRUT", false);

    xlib.ChangeProperty(display, my_window, net_wm_strut_partial, XA_CARDINAL, 32,
                    xlib.PropModeReplace, cast(^libc.uchar)&strut[0], 12)

    xlib.ChangeProperty(display, my_window, net_wm_strut, XA_CARDINAL, 32,
                    xlib.PropModeReplace, cast(^libc.uchar)&strut[0], 4)


    attr : xlib.XWindowAttributes
    attr.override_redirect = false
    xlib.ChangeWindowAttributes(display, my_window, {.CWOverrideRedirect}, &attr);
    raylib.EndDrawing()
  }
  raylib.CloseWindow()
}
