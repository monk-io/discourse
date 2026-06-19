// Builds the handler that sends a picked GIF from the chat composer (the
// composer picker's GIF tab). Extracted so the send + draft-reset interplay
// can be unit tested.
//
// The returned handler:
//   - Sends the picked GIF as a chat message in the active context (channel or
//     thread, with inReplyTo when replying in a channel).
//   - On a successful send, resets the *correct* draft (thread when in a
//     thread context, channel otherwise) for the given user.
//   - On send failure, leaves the draft intact so the user can retry.
export function buildGifPickHandler({ api, draft, isThread, currentUser }) {
  const draftHolder = isThread ? draft.thread : draft.channel;

  return async (message) => {
    try {
      await api.sendChatMessage(draft.channel.id, {
        message,
        threadId: isThread ? draft.thread?.id : null,
        inReplyToId: !isThread ? draft.inReplyTo?.id : null,
      });
    } catch {
      return;
    }
    draftHolder?.resetDraft?.(currentUser);
  };
}

// Routes a composer picker selection in chat (shared by the desktop inline
// picker and the mobile dropdown picker): emoji is inserted into the draft,
// any other tab's value (GIF today) is sent immediately as its own message.
export function buildChatPickerSelectHandler({ api, composer, currentUser }) {
  return (value, tab) => {
    if (tab.id === "emoji") {
      composer.onSelectEmoji(value);
      return;
    }

    buildGifPickHandler({
      api,
      draft: composer.draft,
      isThread: composer.context === "thread",
      currentUser,
    })(value);
  };
}
