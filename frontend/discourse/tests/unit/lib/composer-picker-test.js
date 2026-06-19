import { setupTest } from "ember-qunit";
import { module, test } from "qunit";
import {
  composerPickerTabs,
  registerComposerPickerTab,
  resetComposerPickerTabs,
} from "discourse/lib/composer-picker";

module("Unit | Lib | composer-picker", function (hooks) {
  setupTest(hooks);

  hooks.beforeEach(function () {
    this.siteSettings = this.owner.lookup("service:site-settings");
    this.siteSettings.enable_emoji = true;
    this.siteSettings.enable_gifs = true;
  });

  hooks.afterEach(function () {
    resetComposerPickerTabs();
  });

  test("includes core tabs gated by site settings", function (assert) {
    assert.deepEqual(
      composerPickerTabs(this.owner).map((tab) => tab.id),
      ["emoji", "gifs"],
      "both core tabs are enabled by default"
    );

    this.siteSettings.enable_gifs = false;
    assert.deepEqual(
      composerPickerTabs(this.owner).map((tab) => tab.id),
      ["emoji"],
      "drops the gif tab when gifs are disabled"
    );

    this.siteSettings.enable_gifs = true;
    this.siteSettings.enable_emoji = false;
    assert.deepEqual(
      composerPickerTabs(this.owner).map((tab) => tab.id),
      ["gifs"],
      "drops the emoji tab when emoji is disabled"
    );

    this.siteSettings.enable_gifs = false;
    assert.deepEqual(
      composerPickerTabs(this.owner).map((tab) => tab.id),
      [],
      "no tabs when nothing is enabled"
    );
  });

  test("registered tabs are sorted by priority, highest first", function (assert) {
    registerComposerPickerTab({
      id: "stickers",
      priority: 200,
      enabled: () => true,
    });

    assert.deepEqual(
      composerPickerTabs(this.owner).map((tab) => tab.id),
      ["stickers", "emoji", "gifs"],
      "the higher-priority custom tab leads"
    );
  });

  test("registered tabs can be disabled", function (assert) {
    registerComposerPickerTab({
      id: "stickers",
      priority: 200,
      enabled: () => false,
    });

    assert.false(
      composerPickerTabs(this.owner).some((tab) => tab.id === "stickers"),
      "a disabled custom tab is excluded"
    );
  });
});
