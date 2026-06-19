import EmojiPickerContent from "discourse/components/emoji-picker/content";

// Emoji tab for the composer picker. Adapts EmojiPickerContent's
// `didSelectEmoji` to the generic `onSelect` contract the picker shell uses.
const EmojiPanel = <template>
  <EmojiPickerContent
    @didSelectEmoji={{@onSelect}}
    @close={{@close}}
    @context={{@context}}
    @term={{@term}}
  />
</template>;

export default EmojiPanel;
