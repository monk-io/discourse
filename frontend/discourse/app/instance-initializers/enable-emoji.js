import { registerEmoji } from "pretty-text/emoji";
import PreloadStore from "discourse/lib/preload-store";

export default {
  initialize(owner) {
    const siteSettings = owner.lookup("service:site-settings");

    if (!siteSettings.enable_emoji) {
      return;
    }

    // The composer toolbar button is registered by the composer-picker
    // initializer, which hosts the emoji picker as one tab alongside GIFs.

    (PreloadStore.get("customEmoji") || []).forEach((emoji) =>
      registerEmoji(emoji.name, emoji.url, emoji.group)
    );
  },
};
