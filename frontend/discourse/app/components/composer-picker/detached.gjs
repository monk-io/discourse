import ComposerPickerContent from "discourse/components/composer-picker/content";

// Composer picker for imperative use with the menu service (`menu.show`).
// The hosting surface supplies `onSelect`, `context`, `initialTab` and `term`
// through the menu's `data` option.
const ComposerPickerDetached = <template>
  <ComposerPickerContent
    @close={{@close}}
    @term={{@data.term}}
    @initialTab={{@data.initialTab}}
    @onSelect={{@data.onSelect}}
    @context={{@data.context}}
  />
</template>;

export default ComposerPickerDetached;
