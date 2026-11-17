/* -*- Mode: Vala; indent-tabs-mode: nil; tab-width: 4 -*-
 *
 * Copyright (C) 2011,2012 Canonical Ltd
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License version 3 as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authors: Robert Ancell <robert.ancell@canonical.com>
 *          Michael Terry <michael.terry@canonical.com>
 */

public class MainWindow : Gtk.Window
{
    public MenuBar menubar;

    private List<Monitor> monitors;
    private Monitor? primary_monitor;
    private Monitor active_monitor;
    private string only_on_monitor;
    private bool monitor_setting_ok;
    /* On Wayland: the monitor the window is fullscreen on, the monitor the
       pointer moved the login box to (with only-on-monitor auto), and the
       background windows on the other monitors */
    private int wayland_monitor = -1;
    private string? wayland_pointer_monitor = null;
    private List<OtherMonitorWindow> other_monitor_windows = null;
    private bool windows_shown = false;
    private Background background;
    private Gtk.Box login_box;
    private Gtk.Box hbox;
    private Gtk.Box content_box;
    private Gtk.Button back_button;
    private ShutdownDialog? shutdown_dialog = null;
    private bool do_resize;

    public ListStack stack;

    // Menubar is smaller, but with shadow, we reserve more space
    public const int MENUBAR_HEIGHT = 32;

    construct
    {
        events |= Gdk.EventMask.POINTER_MOTION_MASK;

        var accel_group = new Gtk.AccelGroup ();
        add_accel_group (accel_group);

        var bg_color = Gdk.RGBA ();
        set_name ("main-window");
        bg_color.parse (UGSettings.get_string (UGSettings.KEY_BACKGROUND_COLOR));
        try
        {
            var bg_provider = new Gtk.CssProvider ();
            bg_provider.load_from_data (
                "#main-window { background-color: %s; }".printf (bg_color.to_string ()), -1);
            get_style_context ().add_provider (bg_provider,
                                               Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
        catch (Error e)
        {
            debug ("Internal error setting background color: %s", e.message);
        }
        get_accessible ().set_name (_("Login Screen"));
        /* has_resize_grip = false — removed, deprecated since GTK 3.14 */
        SlickGreeter.add_style_class (this);

        background = new Background ();
        add (background);
        SlickGreeter.add_style_class (background);

        login_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        login_box.show ();
        background.add (login_box);

        /* Box for menubar shadow */
        var menubox = new Gtk.EventBox ();
        var shadow_path = Path.build_filename (Config.PKGDATADIR,
                                               "shadow.png", null);
        var shadow_style = "";
        if (FileUtils.test (shadow_path, FileTest.EXISTS))
        {
            shadow_style = "background-image: url('%s');background-repeat: repeat;".printf(shadow_path);
        }
        try
        {
            var style = new Gtk.CssProvider ();
            style.load_from_data ("* {background-color: transparent;%s}".printf(shadow_style), -1);
            var context = menubox.get_style_context ();
            context.add_provider (style,
                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
        catch (Error e)
        {
            debug ("Internal error loading menubox style: %s", e.message);
        }
        menubox.set_size_request (-1, MENUBAR_HEIGHT);
        menubox.show ();
        login_box.add (menubox);
        SlickGreeter.add_style_class (menubox);

        menubar = new MenuBar (background, accel_group, this);
        menubar.hexpand = true;
        menubar.show ();
        menubox.add (menubar);
        SlickGreeter.add_style_class (menubar);

        content_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        content_box.expand = true;
        content_box.show ();
        login_box.add (content_box);

        var content_align = UGSettings.get_string(UGSettings.KEY_CONTENT_ALIGN);

        hbox = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        hbox.vexpand = true;
        if (content_align == "left")
            hbox.halign = Gtk.Align.START;
        else if (content_align == "right")
            hbox.halign = Gtk.Align.END;
        else
            hbox.halign = Gtk.Align.CENTER;

        if (content_align == "center")
        {
            // offset for back button
            hbox.margin_end = grid_size;
        }

        hbox.show ();
        content_box.add (hbox);

        var back_align = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        // Hack to avoid gtk 3.20's new allocate logic, which messes us up.
        back_align.resize_mode = Gtk.ResizeMode.QUEUE;
        back_align.set_size_request (grid_size, -1);
        back_align.margin_bottom = MENUBAR_HEIGHT;
        back_align.halign = Gtk.Align.CENTER;
        back_align.valign = Gtk.Align.CENTER;
        back_align.show ();
        hbox.add (back_align);

        back_button = new FlatButton ();
        back_button.get_accessible ().set_name (_("Back"));
        Gtk.button_set_focus_on_click (back_button, false);
        var image = new Gtk.Image.from_file (Path.build_filename (Config.PKGDATADIR, "arrow_left.svg", null));
        image.show ();
        back_button.set_size_request (grid_size - GreeterList.BORDER * 2, grid_size - GreeterList.BORDER * 2);
        back_button.add (image);
        back_button.clicked.connect (pop_list);
        back_align.add (back_button);

        var stack_align = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        stack_align.halign = Gtk.Align.START;
        stack_align.valign = Gtk.Align.FILL;
        stack_align.vexpand = true;
        stack_align.show ();
        hbox.add (stack_align);

        stack = new ListStack ();
        stack.valign = Gtk.Align.FILL;
        stack.vexpand = true;
        stack.show ();
        stack_align.add (stack);

        add_user_list ();

        primary_monitor = null;
        do_resize = false;

        only_on_monitor = UGSettings.get_string(UGSettings.KEY_ONLY_ON_MONITOR);
        monitor_setting_ok = only_on_monitor == "auto";

        /* (On Wayland the test window is the real one: a Wayland client can't
           place or span a window over simulated monitors) */
        if (SlickGreeter.singleton.test_mode && !SlickGreeter.is_wayland ())
        {
            /* Simulate an 800x600 monitor to the left of a 640x480 monitor */
            monitors = new List<Monitor> ();
            monitors.append (new Monitor (0, 0, 800, 600));
            monitors.append (new Monitor (800, 120, 640, 480));
            background.set_monitors (monitors);
            move_to_monitor (monitors.nth_data (0));
            resize (background.width, background.height);
        }
        else
        {
            var screen = get_screen ();
            screen.monitors_changed.connect (monitors_changed_cb);
            monitors_changed_cb (screen);
        }

        /* Force a call on login_box.show()...
            This fixes the following issue:
            When the greeter starts, the login box looks too small, its entry isn't visible and
            its session button isn't sensitive/clickable.
            Pressing Escape fixes the box but not the session button..
            Scrolling up/down fixes both..
        */
        if (login_box.sensitive) {
            login_box.show();
        }
    }

    public void push_list (GreeterList widget)
    {
        stack.push (widget);

        if (stack.num_children > 1)
            back_button.show ();
    }

    public void pop_list ()
    {
        if (stack.num_children <= 2)
            back_button.hide ();

        stack.pop ();
    }

    public override void size_allocate (Gtk.Allocation allocation)
    {
        base.size_allocate (allocation);

        if (content_box != null)
        {
            var content_align = UGSettings.get_string(UGSettings.KEY_CONTENT_ALIGN);
            content_box.margin_start  = get_grid_offset (get_allocated_width ()) + (content_align == "left" ? grid_size : 0);
            content_box.margin_end    = get_grid_offset (get_allocated_width ()) + (content_align == "right" ? grid_size : 0);
            content_box.margin_top = get_grid_offset (get_allocated_height ());
            content_box.margin_bottom = get_grid_offset (get_allocated_height ());
        }
    }

    public override void realize ()
    {
        base.realize ();
        background.set_surface (get_window ().create_similar_surface (Cairo.Content.COLOR, 1, 1));
    }

    /* Start loading the system background before the window is shown (the
       user list sets the background once it is shown) */
    public void show_all_when_ready (owned SlickGreeter.ShownFunc shown)
    {
        SlickGreeter.show_when_ready (this, () => {
            var ready = is_background_ready ();
            foreach (var w in other_monitor_windows)
                ready = w.is_background_ready () && ready;
            return ready;
        }, () => {
            windows_shown = true;
            foreach (var w in other_monitor_windows)
                w.show ();
            shown ();
        });
    }

    public bool is_background_ready ()
    {
        if (!background.get_realized ())
            background.realize ();
        if (background.current_background == background.fallback_color &&
            background.system_background != background.fallback_color)
            background.current_background = null;

        return background.is_ready ();
    }

    public void before_session_start()
    {
        debug ("Killing orca and onboard");
        menubar.cleanup();
    }

    /* Setup the size and position of the window */
    public void setup_window ()
    {
        if (SlickGreeter.is_wayland ())
        {
            /* A Wayland client can't place a window or span one over several
               monitors: be fullscreen on the chosen one */
            resize (background.width, background.height);
            if (wayland_monitor >= 0)
                fullscreen_on_monitor (get_screen (), wayland_monitor);
            else
                fullscreen ();
            move_to_monitor (primary_monitor);
            return;
        }

        resize (background.width, background.height);
        move (0, 0);
        move_to_monitor (primary_monitor);
    }

    /* The name in a monitor's EDID (its monitor name descriptor), which is
       what GDK's monitor model is on Wayland; only-on-monitor names the
       connector, as on X11 (DP-1), so it is looked up through sysfs */
    private static string? edid_name_for_connector (string connector)
    {
        try
        {
            var dir = Dir.open ("/sys/class/drm");
            string? entry;

            while ((entry = dir.read_name ()) != null)
            {
                /* card1-DP-1 */
                var dash = entry.index_of ("-");
                if (!entry.has_prefix ("card") || dash < 0 || entry.substring (dash + 1) != connector)
                    continue;

                uint8[] edid;
                FileUtils.get_data (Path.build_filename ("/sys/class/drm", entry, "edid"), out edid);

                for (var offset = 54; offset + 18 <= edid.length && offset <= 108; offset += 18)
                {
                    if (edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 2] == 0 && edid[offset + 3] == 0xfc)
                    {
                        var name = new StringBuilder ();
                        for (var i = offset + 5; i < offset + 18 && edid[i] != 10; i++)
                            name.append_c ((char) edid[i]);
                        return name.str.strip ();
                    }
                }
            }
        }
        catch (Error e)
        {
            debug ("Could not read the EDID of %s: %s", connector, e.message);
        }

        return null;
    }

    private void wayland_monitors_changed (Gdk.Display display)
    {
        var edid_name = only_on_monitor == "auto" ? null : edid_name_for_connector (only_on_monitor);

        wayland_monitor = -1;
        for (var i = 0; i < display.get_n_monitors (); i++)
        {
            var model = display.get_monitor (i).get_model ();
            if (model != null && (model == only_on_monitor || model == edid_name))
            {
                wayland_monitor = i;
                monitor_setting_ok = true;
                break;
            }
        }
        /* Otherwise the one the pointer moved it to, or as there is no
           primary monitor on Wayland, the first one */
        for (var i = 0; wayland_monitor < 0 && wayland_pointer_monitor != null && i < display.get_n_monitors (); i++)
        {
            if (display.get_monitor (i).get_model () == wayland_pointer_monitor)
                wayland_monitor = i;
        }
        if (wayland_monitor < 0 && display.get_n_monitors () > 0)
            wayland_monitor = 0;

        monitors = new List<Monitor> ();
        primary_monitor = null;
        if (wayland_monitor >= 0)
        {
            var geometry = display.get_monitor (wayland_monitor).get_geometry ();
            debug ("Wayland: using monitor %d (%s), %dx%d", wayland_monitor,
                   display.get_monitor (wayland_monitor).get_model (), geometry.width, geometry.height);

            /* The window is that monitor alone */
            primary_monitor = new Monitor (0, 0, geometry.width, geometry.height);
            monitors.append (primary_monitor);
        }

        background.set_monitors (monitors);

        foreach (var w in other_monitor_windows)
            w.destroy ();
        other_monitor_windows = new List<OtherMonitorWindow> ();
        for (var i = 0; i < display.get_n_monitors (); i++)
        {
            if (i == wayland_monitor)
                continue;

            var w = new OtherMonitorWindow (display, i, background, windows_shown);
            w.entered.connect (wayland_pointer_entered);
            other_monitor_windows.append (w);
        }

        if (do_resize)
            setup_window ();
        else
            do_resize = true;
    }

    /* The pointer moved to another monitor: move the login box there, as on
       X11, unless only-on-monitor names a monitor that is connected */
    private void wayland_pointer_entered (OtherMonitorWindow w)
    {
        if (monitor_setting_ok && only_on_monitor != "auto")
            return;

        var display = get_display ();
        if (w.monitor_index >= display.get_n_monitors ())
            return;

        wayland_pointer_monitor = display.get_monitor (w.monitor_index).get_model ();
        do_resize = true;
        /* (After this event: it destroys the window it came from) */
        Idle.add (() => {
            wayland_monitors_changed (get_display ());
            present ();
            return false;
        });
    }

    private void monitors_changed_cb (Gdk.Screen screen)
    {
        Gdk.Display display = screen.get_display();

        if (SlickGreeter.is_wayland ())
        {
            wayland_monitors_changed (display);
            return;
        }

        Gdk.Monitor primary = display.get_primary_monitor();
        Gdk.Rectangle geometry;

        monitors = new List<Monitor> ();
        primary_monitor = null;

        for (var i = 0; i < display.get_n_monitors (); i++)
        {
            Gdk.Monitor monitor = display.get_monitor(i);
            geometry = monitor.get_geometry ();
            debug ("Monitor %d is %dx%d pixels at %d,%d", i, geometry.width, geometry.height, geometry.x, geometry.y);

            if (monitor_is_unique_position (display, i))
            {
                var greeter_monitor = new Monitor (geometry.x, geometry.y, geometry.width, geometry.height);
                var plug_name = monitor.get_model();
                monitors.append (greeter_monitor);

                if (plug_name == only_on_monitor)
                    monitor_setting_ok = true;

                if (plug_name == only_on_monitor || primary_monitor == null || primary == monitor)
                    primary_monitor = greeter_monitor;
            }
        }

        debug ("MainWindow is %dx%d pixels", background.width, background.height);

        background.set_monitors (monitors);

        if(do_resize)
        {
            setup_window ();
        }
        else
        {
            do_resize = true;
        }
    }

    /* Check if a monitor has a unique position */
    private bool monitor_is_unique_position (Gdk.Display display, int n)
    {
        Gdk.Rectangle g0;
        Gdk.Monitor mon0;
        mon0 = display.get_monitor(n);
        g0 = mon0.get_geometry ();

        for (var i = n + 1; i < display.get_n_monitors (); i++)
        {
            Gdk.Rectangle g1;
            Gdk.Monitor mon1;
            mon1 = display.get_monitor(i);
            g1 = mon1.get_geometry();

            if (g0.x == g1.x && g0.y == g1.y)
                return false;
        }

        return true;
    }

    public override bool motion_notify_event (Gdk.EventMotion event)
    {
        if (!monitor_setting_ok || only_on_monitor == "auto")
        {
            var x = (int) (event.x + 0.5);
            var y = (int) (event.y + 0.5);

            /* Get motion event relative to this widget */
            if (event.window != get_window ())
            {
                int w_x, w_y;
                get_window ().get_origin (out w_x, out w_y);
                x -= w_x;
                y -= w_y;
                event.window.get_origin (out w_x, out w_y);
                x += w_x;
                y += w_y;
            }

            foreach (var m in monitors)
            {
                if (x >= m.x && x <= m.x + m.width && y >= m.y && y <= m.y + m.height)
                {
                    move_to_monitor (m);
                    break;
                }
            }
        }

        return false;
    }

    private void move_to_monitor (Monitor monitor)
    {
        active_monitor = monitor;
        login_box.set_size_request (monitor.width, monitor.height);
        background.set_active_monitor (monitor);
        background.move (login_box, monitor.x, monitor.y);

        if (shutdown_dialog != null)
        {
            shutdown_dialog.set_active_monitor (monitor);
            background.move (shutdown_dialog, monitor.x, monitor.y);
        }
    }

    private void add_user_list ()
    {
        GreeterList greeter_list;
        greeter_list = new UserList (background, menubar);
        greeter_list.show ();
        SlickGreeter.add_style_class (greeter_list);
        
        // Connect Background to DashBox transitions for synchronized redraws
        background.connect_to_dashbox_transitions (greeter_list.greeter_box);
        
        push_list (greeter_list);
    }

    public override bool key_press_event (Gdk.EventKey event)
    {
        var top = stack.top ();

        if (stack.top () is UserList)
        {
            var user_list = stack.top () as UserList;
            var shift_mask = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.MOD1_MASK;
            var control_mask = Gdk.ModifierType.SHIFT_MASK | Gdk.ModifierType.MOD1_MASK;
            var alt_mask = Gdk.ModifierType.CONTROL_MASK | Gdk.ModifierType.SHIFT_MASK;
            if (((event.keyval == Gdk.Key.Shift_L || event.keyval == Gdk.Key.Shift_R) && (event.state & shift_mask) == shift_mask) ||
                ((event.keyval == Gdk.Key.Control_L || event.keyval == Gdk.Key.Control_R) && (event.state & control_mask) == control_mask) ||
                ((event.keyval == Gdk.Key.Alt_L || event.keyval == Gdk.Key.Alt_R) && (event.state & alt_mask) == alt_mask))
            {
                debug ("Hidden user key combination detected");
                user_list.show_hidden_users = ! user_list.show_hidden_users;
                return true;
            }
        }
        else if (stack.top () is SessionList) {
            // Session list is open
            switch (event.keyval) {
                case Gdk.Key.Escape:
                case Gdk.Key.Left:
                case Gdk.Key.KP_Left:
                    pop_list();
                    return true;
            }
        }

        switch (event.keyval)
        {
        case Gdk.Key.Escape:
            if (login_box.sensitive)
                top.cancel_authentication ();
            if (shutdown_dialog != null)
                shutdown_dialog.cancel ();
            return true;
        case Gdk.Key.Page_Up:
        case Gdk.Key.KP_Page_Up:
            if (login_box.sensitive)
                top.scroll (GreeterList.ScrollTarget.START);
            return true;
        case Gdk.Key.Page_Down:
        case Gdk.Key.KP_Page_Down:
            if (login_box.sensitive)
                top.scroll (GreeterList.ScrollTarget.END);
            return true;
        case Gdk.Key.Up:
        case Gdk.Key.KP_Up:
            if (login_box.sensitive)
                top.scroll (GreeterList.ScrollTarget.UP);
            return true;
        case Gdk.Key.Down:
        case Gdk.Key.KP_Down:
            if (login_box.sensitive)
                top.scroll (GreeterList.ScrollTarget.DOWN);
            return true;
        case Gdk.Key.F10:
            if (login_box.sensitive)
                menubar.select_first (false);
            return true;
        case Gdk.Key.PowerOff:
            show_shutdown_dialog (ShutdownDialogType.SHUTDOWN);
            return true;
        case Gdk.Key.Print:
            debug ("Taking screenshot");
            var root = Gdk.get_default_root_window ();
            var screenshot = Gdk.pixbuf_get_from_window (root, 0, 0, root.get_width (), root.get_height ());
            try
            {
                screenshot.save ("Screenshot.png", "png", null);
            }
            catch (Error e)
            {
                warning ("Failed to save screenshot: %s", e.message);
            }
            return true;
        case Gdk.Key.z:
            if (SlickGreeter.singleton.test_mode && (event.state & Gdk.ModifierType.MOD1_MASK) != 0)
            {
                show_shutdown_dialog (ShutdownDialogType.SHUTDOWN);
                return true;
            }
            break;
        case Gdk.Key.Z:
            if (SlickGreeter.singleton.test_mode && (event.state & Gdk.ModifierType.MOD1_MASK) != 0)
            {
                show_shutdown_dialog (ShutdownDialogType.RESTART);
                return true;
            }
            break;
        }

        return base.key_press_event (event);
    }

    public void set_keyboard_state ()
    {
        menubar.set_keyboard_state ();
    }

    public void show_shutdown_dialog (ShutdownDialogType type)
    {
        if (shutdown_dialog != null)
            shutdown_dialog.destroy ();

        /* Stop input to login box */
        login_box.sensitive = false;

        shutdown_dialog = new ShutdownDialog (type, background);
        shutdown_dialog.closed.connect (close_shutdown_dialog);
        background.add (shutdown_dialog);
        move_to_monitor (active_monitor);
        shutdown_dialog.visible = true;
    }

    public void close_shutdown_dialog ()
    {
        if (shutdown_dialog == null)
            return;

        shutdown_dialog.destroy ();
        shutdown_dialog = null;

        login_box.sensitive = true;
    }
}

/* On Wayland: the background on a monitor the login box isn't on, in a
   fullscreen window of its own */
private class OtherMonitorWindow : Gtk.Window
{
    public int monitor_index { get; private set; }
    public signal void entered (OtherMonitorWindow window);

    private Background background;
    private Background main_background;
    private ulong main_background_handler;

    public OtherMonitorWindow (Gdk.Display display, int monitor_index, Background main_background, bool show_now)
    {
        this.monitor_index = monitor_index;
        this.main_background = main_background;

        decorated = false;
        accept_focus = false;
        focus_on_map = false;
        add_events (Gdk.EventMask.ENTER_NOTIFY_MASK);

        /* The main window's background color, shown until the background is
           drawn (instead of the theme's window color, white with Adwaita) */
        var bg_color = Gdk.RGBA ();
        if (!bg_color.parse (UGSettings.get_string (UGSettings.KEY_BACKGROUND_COLOR)))
            bg_color.parse ("#000000");
        try
        {
            var bg_provider = new Gtk.CssProvider ();
            bg_provider.load_from_data ("window { background-color: %s; }".printf (bg_color.to_string ()), -1);
            get_style_context ().add_provider (bg_provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);
        }
        catch (Error e)
        {
            debug ("Internal error setting background color: %s", e.message);
        }

        var geometry = display.get_monitor (monitor_index).get_geometry ();
        var monitors = new List<Monitor> ();
        monitors.append (new Monitor (0, 0, geometry.width, geometry.height));

        background = new Background ();
        SlickGreeter.add_style_class (background);
        background.set_monitors (monitors);
        add (background);
        set_default_size (geometry.width, geometry.height);

        /* Follow the main window's background, which changes with the
           selected user */
        main_background_handler = main_background.notify["current-background"].connect (() => {
            background.current_background = main_background.current_background;
        });

        realize ();
        background.current_background = main_background.current_background;
        fullscreen_on_monitor (get_screen (), monitor_index);
        if (show_now)
            SlickGreeter.show_when_ready (this, () => is_background_ready ());
    }

    public bool is_background_ready ()
    {
        if (!background.get_realized ())
        {
            background.realize ();
            background.current_background = main_background.current_background;
        }
        return background.is_ready ();
    }

    public override void realize ()
    {
        base.realize ();
        background.set_surface (get_window ().create_similar_surface (Cairo.Content.COLOR, 1, 1));
    }

    public override void destroy ()
    {
        if (main_background_handler != 0)
        {
            main_background.disconnect (main_background_handler);
            main_background_handler = 0;
        }
        base.destroy ();
    }

    public override bool enter_notify_event (Gdk.EventCrossing event)
    {
        entered (this);
        return false;
    }
}
