public class UserAvatar : CachedImage
{
    public const int AVATAR_SIZE = 32;
    public const int AVATAR_MARGIN = 6;

    private string? _avatar_path;
    public string? avatar_path 
    {
        get { return _avatar_path; }
        set { 
            _avatar_path = value;
            update_avatar();
        }
    }

    private bool _is_small = false;
    public bool is_small {
        get { return _is_small; }
        set {
            _is_small = value;
            update_avatar();
        }
    }

    public UserAvatar()
    {
        Object();
        setup_avatar();
    }

    private void setup_avatar()
    {
        // Keep a fixed size of 32px for display
        set_size_request(AVATAR_SIZE, AVATAR_SIZE);
        margin_end = AVATAR_MARGIN;
        halign = Gtk.Align.CENTER;
        hexpand = false;
        vexpand = false;

        // The scale is known once the avatar is on a monitor
        notify["scale-factor"].connect (update_avatar);
    }

    private void update_avatar()
    {
        if (avatar_path != null)
        {
            try
            {
                // Draw at the monitor's scale, in a surface of that scale, so
                // the avatar stays AVATAR_SIZE logical pixels (a pixbuf would
                // be shown at its pixel size, cut off by the layout)
                var scale_factor = int.max (get_scale_factor (), 1);
                var pixel_size = AVATAR_SIZE * scale_factor;

                // Fill the circle: scale the shorter side to the circle and
                // centre the picture (a picture that isn't square would
                // otherwise leave part of the circle empty)
                var image = new Gdk.Pixbuf.from_file(avatar_path);
                var fill = double.max(
                    (double) pixel_size / image.width,
                    (double) pixel_size / image.height
                );
                var width = int.max((int) Math.ceil(image.width * fill), pixel_size);
                var height = int.max((int) Math.ceil(image.height * fill), pixel_size);
                var pixbuf = image.scale_simple(width, height, Gdk.InterpType.BILINEAR);

                // Create a circular image
                var surface = new Cairo.ImageSurface(
                    Cairo.Format.ARGB32,
                    pixel_size,
                    pixel_size
                );
                var cr = new Cairo.Context(surface);

                // Draw a circle
                cr.arc(
                    pixel_size / 2.0,
                    pixel_size / 2.0,
                    pixel_size / 2.0,
                    0,
                    2 * Math.PI
                );
                cr.clip();

                // Draw the image
                Gdk.cairo_set_source_pixbuf(
                    cr,
                    pixbuf,
                    (pixel_size - width) / 2.0,
                    (pixel_size - height) / 2.0
                );
                cr.paint();

                surface.set_device_scale (scale_factor, scale_factor);
                set_from_surface (surface);
                show();
            }
            catch (Error e)
            {
                warning("Failed to load avatar: %s", e.message);
                hide();
            }
        }
        else
        {
            hide();
        }
    }
}
