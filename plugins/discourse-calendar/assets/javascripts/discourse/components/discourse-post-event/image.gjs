import getURL from "discourse/lib/get-url";

<template>
  {{#if @imageUpload}}
    <section class="event__section event-image">
      <a
        class={{if @linkToPost "event-image__link" "lightbox"}}
        href={{if @linkToPost (getURL @postUrl) @imageUpload.url}}
        rel={{if @linkToPost "noopener noreferrer"}}
      >
        <img src={{@imageUpload.url}} alt={{@alt}} />
      </a>
    </section>
  {{/if}}
</template>
