/* -*- Mode: Vala; indent-tabs-mode: nil; tab-width: 4 -*-
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
 */

/* An on-screen keyboard drawn by the greeter itself, for the Wayland login
 * window. Onboard can't be used there: it is an X11 program, embedded over
 * XEmbed, and typing through XTest, and the Wayland greeter runs in Muffin
 * without an X server. Like the keyboards built into Cinnamon and GNOME Shell,
 * it is part of what draws the screen, so its keys go to the greeter's own
 * widgets as key events: the focused entry, Enter, Tab and the arrows behave
 * as with a real keyboard.
 *
 * The keys are positions on a keyboard (evdev key codes), labelled with what
 * the current layout gives them, so the keyboard follows the layout Muffin
 * set for the login window. They are plain GTK buttons, so the GTK theme,
 * the font and High Contrast set for the login window style it; themes can
 * address it as #onscreen-keyboard and its keys as .osk-key. */

public class OnscreenKeyboard : Gtk.Grid
{
    /* Emitted by the hide key */
    public signal void hide_requested ();

    private enum Action
    {
        KEY,
        SHIFT,
        CAPS,
        HIDE
    }

    private class Key : Gtk.Button
    {
        public uint keycode;
        public Action action;
        public bool is_char;
        public string? symbol;

        public Key (uint keycode, Action action, string? symbol)
        {
            this.keycode = keycode;
            this.action = action;
            this.symbol = symbol;
            is_char = symbol == null && action == Action.KEY;
            can_focus = false;
            focus_on_click = false;
            /* Each finger presses its own key */
            add_events (Gdk.EventMask.TOUCH_MASK);
            get_style_context ().add_class ("osk-key");
            if (!is_char)
                get_style_context ().add_class ("osk-special-key");
        }
    }

    /* A row: key codes (evdev + 8, as GDK gives them) and widths in half
       keys; every row is 30 half keys wide. Negative codes are the
       keyboard's own keys. */
    private const int SHIFT = -1;
    private const int CAPS = -2;
    private const int HIDE = -3;
    private const int COLUMNS = 30;

    private const int[] ROW0 = { 49, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 };
    private const int[] ROW0_W = { 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 4 };
    private const int[] ROW1 = { 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 51 };
    private const int[] ROW1_W = { 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3 };
    private const int[] ROW2 = { CAPS, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 36 };
    private const int[] ROW2_W = { 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 5 };
    private const int[] ROW3 = { SHIFT, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, SHIFT };
    private const int[] ROW3_W = { 4, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 6 };
    private const int[] ROW4 = { 9, HIDE, 65, 113, 111, 116, 114 };
    private const int[] ROW4_W = { 3, 3, 16, 2, 2, 2, 2 };

    private const uint KEYCODE_ESCAPE = 9;
    private const uint KEYCODE_BACKSPACE = 22;
    private const uint KEYCODE_TAB = 23;
    private const uint KEYCODE_RETURN = 36;
    private const uint KEYCODE_SPACE = 65;
    private const uint KEYCODE_UP = 111;
    private const uint KEYCODE_LEFT = 113;
    private const uint KEYCODE_RIGHT = 114;
    private const uint KEYCODE_DOWN = 116;

    /* Holding a key repeats it, as a real keyboard does */
    private const uint REPEAT_DELAY = 500;
    private const uint REPEAT_INTERVAL = 50;

    private List<Key> keys = null;
    private bool shift = false;
    private bool caps = false;
    private Gdk.Keymap keymap;
    private uint repeat_id = 0;
    /* The touch whose key repeats, or null for the mouse */
    private unowned Gdk.EventSequence? repeat_sequence = null;

    construct
    {
        set_name ("onscreen-keyboard");
        get_style_context ().add_class ("osk");
        get_style_context ().add_class (Gtk.STYLE_CLASS_BACKGROUND);
        SlickGreeter.add_style_class (this);
        column_homogeneous = true;
        row_homogeneous = true;
        column_spacing = 4;
        row_spacing = 4;
        margin = 6;
        no_show_all = true;

        add_row (0, ROW0, ROW0_W);
        add_row (1, ROW1, ROW1_W);
        add_row (2, ROW2, ROW2_W);
        add_row (3, ROW3, ROW3_W);
        add_row (4, ROW4, ROW4_W);

        keymap = Gdk.Keymap.get_for_display (get_display ());
        keymap.keys_changed.connect (update_labels);
        keymap.state_changed.connect (() => {
            if (caps != keymap.get_caps_lock_state ())
            {
                caps = keymap.get_caps_lock_state ();
                update_labels ();
            }
        });
        caps = keymap.get_caps_lock_state ();
        update_labels ();

        foreach (var key in keys)
            key.show_all ();
    }

    public override void unmap ()
    {
        stop_repeat ();
        base.unmap ();
    }

    private void add_row (int row, int[] codes, int[] widths)
    {
        var column = 0;
        for (var i = 0; i < codes.length; i++)
        {
            Key key;
            switch (codes[i])
            {
            case SHIFT:
                key = new Key (0, Action.SHIFT, "⇧");
                key.get_accessible ().set_name (_("Shift"));
                break;
            case CAPS:
                key = new Key (0, Action.CAPS, "⇪");
                key.get_accessible ().set_name (_("Caps Lock"));
                break;
            case HIDE:
                key = new Key (0, Action.HIDE, null);
                key.get_accessible ().set_name (_("Hide the onscreen keyboard"));
                var image = new Gtk.Image.from_icon_name ("input-keyboard-symbolic", Gtk.IconSize.LARGE_TOOLBAR);
                key.add (image);
                break;
            default:
                key = new Key (codes[i], Action.KEY, special_symbol (codes[i]));
                break;
            }

            if (key.action == Action.KEY)
            {
                key.button_press_event.connect ((w, e) => key_pressed ((Key) w, e));
                key.button_release_event.connect ((w, e) => key_released ((Key) w, e));
                key.touch_event.connect ((w, e) => key_touched ((Key) w, e));
            }
            else
                key.clicked.connect ((w) => special_clicked ((Key) w));

            attach (key, column, row, widths[i], 1);
            column += widths[i];
            keys.append (key);
        }
        assert (column == COLUMNS);
    }

    private static string? special_symbol (uint keycode)
    {
        switch (keycode)
        {
        case KEYCODE_ESCAPE: return _("Esc");
        case KEYCODE_BACKSPACE: return "⌫";
        case KEYCODE_TAB: return "⇥";
        case KEYCODE_RETURN: return "⏎";
        case KEYCODE_SPACE: return " ";
        case KEYCODE_UP: return "↑";
        case KEYCODE_LEFT: return "←";
        case KEYCODE_RIGHT: return "→";
        case KEYCODE_DOWN: return "↓";
        default: return null;
        }
    }

    private Gdk.ModifierType modifier_state ()
    {
        Gdk.ModifierType state = 0;
        if (shift)
            state |= Gdk.ModifierType.SHIFT_MASK;
        if (caps)
            state |= Gdk.ModifierType.LOCK_MASK;
        return state;
    }

    private uint keyval_for (uint keycode)
    {
        uint keyval;
        int effective_group, level;
        Gdk.ModifierType consumed;

        if (!keymap.translate_keyboard_state (keycode, modifier_state (), 0,
                                              out keyval, out effective_group,
                                              out level, out consumed))
            return 0;
        return keyval;
    }

    /* What the layout puts on a key; a dead key shows its accent */
    private string label_for (uint keyval)
    {
        var c = (unichar) Gdk.keyval_to_unicode (keyval);
        if (c != 0 && !c.iscntrl ())
            return c.to_string ();

        var name = Gdk.keyval_name (keyval);
        if (name == null)
            return "";
        if (name.has_prefix ("dead_"))
        {
            switch (name)
            {
            case "dead_grave": return "`";
            case "dead_acute": return "´";
            case "dead_circumflex": return "^";
            case "dead_tilde": return "~";
            case "dead_diaeresis": return "¨";
            case "dead_cedilla": return "¸";
            case "dead_caron": return "ˇ";
            case "dead_ring": return "°";
            default: return name.substring (5);
            }
        }
        return name;
    }

    private void set_key_label (Key key, string text)
    {
        var label = key.get_child () as Gtk.Label;
        if (label == null)
        {
            label = new Gtk.Label (null);
            var attrs = new Pango.AttrList ();
            attrs.insert (Pango.attr_scale_new (1.4));
            label.attributes = attrs;
            label.show ();
            key.add (label);
        }
        label.label = text;
    }

    private void update_labels ()
    {
        foreach (var key in keys)
        {
            var ctx = key.get_style_context ();
            if (key.action == Action.SHIFT)
            {
                if (shift)
                    ctx.add_class ("osk-latched");
                else
                    ctx.remove_class ("osk-latched");
            }
            if (key.action == Action.CAPS)
            {
                if (caps)
                    ctx.add_class ("osk-latched");
                else
                    ctx.remove_class ("osk-latched");
            }

            if (key.action == Action.HIDE)
                continue;
            if (key.symbol != null)
            {
                set_key_label (key, key.symbol);
                continue;
            }

            var keyval = keyval_for (key.keycode);
            set_key_label (key, keyval != 0 ? label_for (keyval) : "");
            key.sensitive = keyval != 0;
        }
    }

    private void special_clicked (Key key)
    {
        switch (key.action)
        {
        case Action.SHIFT:
            shift = !shift;
            update_labels ();
            break;
        case Action.CAPS:
            caps = !caps;
            update_labels ();
            break;
        case Action.HIDE:
            hide_requested ();
            break;
        default:
            break;
        }
    }

    private bool key_pressed (Key key, Gdk.EventButton event)
    {
        /* A touch is handled as a touch (key_touched) */
        if (event.button != 1 || event.type != Gdk.EventType.BUTTON_PRESS ||
            ((Gdk.Event) event).get_pointer_emulated ())
            return false;

        press (key, null);

        /* Let the button show itself pressed */
        return false;
    }

    private bool key_released (Key key, Gdk.EventButton event)
    {
        if (event.button == 1 && !((Gdk.Event) event).get_pointer_emulated () &&
            repeat_sequence == null)
            stop_repeat ();
        return false;
    }

    private bool key_touched (Key key, Gdk.Event event)
    {
        unowned Gdk.EventSequence? sequence = event.get_event_sequence ();

        switch (event.get_event_type ())
        {
        case Gdk.EventType.TOUCH_BEGIN:
            press (key, sequence);
            break;
        case Gdk.EventType.TOUCH_END:
        case Gdk.EventType.TOUCH_CANCEL:
            if (repeat_sequence == sequence)
                stop_repeat ();
            break;
        default:
            break;
        }

        /* Let the button show itself pressed */
        return false;
    }

    /* Type the key, and repeat it while it's held: the last key pressed
       repeats, as on a real keyboard */
    private void press (Key key, Gdk.EventSequence? sequence)
    {
        tap (key);
        stop_repeat ();
        repeat_sequence = sequence;
        repeat_id = Timeout.add (REPEAT_DELAY, () => {
            repeat_id = Timeout.add (REPEAT_INTERVAL, () => {
                tap (key);
                return Source.CONTINUE;
            });
            return Source.REMOVE;
        });
    }

    private void stop_repeat ()
    {
        if (repeat_id != 0)
        {
            Source.remove (repeat_id);
            repeat_id = 0;
        }
        repeat_sequence = null;
    }

    private void tap (Key key)
    {
        var keyval = keyval_for (key.keycode);
        if (keyval == 0)
            return;

        send_key (key.keycode, keyval, true);
        send_key (key.keycode, keyval, false);

        /* Shift applies to one key, as on a phone */
        if (shift && key.is_char)
        {
            shift = false;
            update_labels ();
        }
    }

    /* Deliver the key to the window as if typed, so it reaches the focused
       widget with the window's own key handling */
    private void send_key (uint keycode, uint keyval, bool press)
    {
        var toplevel = get_toplevel ();
        var window = toplevel != null ? toplevel.get_window () : null;
        if (window == null)
            return;

        var event = new Gdk.Event (press ? Gdk.EventType.KEY_PRESS : Gdk.EventType.KEY_RELEASE);
        unowned Gdk.EventKey key_event = (Gdk.EventKey) event;
        /* The event holds a reference to its window, released when it's freed */
        key_event.window = window;
        window.ref ();
        key_event.send_event = 1;
        key_event.time = Gtk.get_current_event_time ();
        key_event.state = modifier_state ();
        key_event.keyval = keyval;
        key_event.hardware_keycode = (uint16) keycode;
        key_event.group = 0;

        var seat = get_display ().get_default_seat ();
        if (seat != null && seat.get_keyboard () != null)
            event.set_device (seat.get_keyboard ());

        Gtk.main_do_event (event);
    }
}
