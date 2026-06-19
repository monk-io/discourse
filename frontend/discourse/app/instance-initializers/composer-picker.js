import ComposerPickerDetached from "discourse/components/composer-picker/detached";
import { composerPickerTabs } from "discourse/lib/composer-picker";
import { withPluginApi } from "discourse/lib/plugin-api";

// Adds a single composer toolbar button that opens the tabbed picker (emoji,
// GIFs, and any registered tab). Replaces the previously separate emoji and
// GIF toolbar buttons.
export default {
  initialize(owner) {
    const tabs = composerPickerTabs(owner);

    if (!tabs.length) {
      return;
    }

    withPluginApi((api) => {
      api.onToolbarCreate((toolbar) => {
        toolbar.addButton({
          id: "emoji",
          group: "extras",
          icon: tabs[0].icon,
          sendAction: () => {
            const menu = api.container.lookup("service:menu");

            menu.show(document.querySelector(".insert-composer-emoji"), {
              identifier: "composer-picker",
              groupIdentifier: "composer-picker",
              component: ComposerPickerDetached,
              modalForMobile: true,
              data: {
                context: "topic",
                onSelect: (value, tab) => {
                  // Route through the toolbar's own text manipulation (the same
                  // object the emoji tab uses) rather than the composer-only
                  // `composer:insert-text` app event, so the value isn't
                  // silently dropped on non-composer editors.
                  const { textManipulation } = toolbar.context;
                  if (tab.id === "emoji") {
                    textManipulation.emojiSelected(value);
                  } else {
                    textManipulation.insertText(value);
                  }
                },
              },
            });
          },
          title: "composer.emoji",
          className: "emoji insert-composer-emoji",
        });
      });
    });
  },
};
