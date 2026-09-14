<template>
  <span class="term-info" :class="{ 'term-info-heading': heading }">
    <span>{{ label }}</span>
    <button
      v-if="definition"
      type="button"
      class="term-info-button"
      :aria-expanded="open"
      :aria-label="`What does ${label} mean?`"
      @click.stop="open = !open"
    >
      i
    </button>
    <span v-if="definition && open" class="term-info-popover" role="note">
      {{ definition }}
    </span>
  </span>
</template>

<script setup>
import { ref } from 'vue'

defineProps({
  label: { type: String, required: true },
  definition: { type: String, default: '' },
  heading: { type: Boolean, default: false },
})

const open = ref(false)
</script>

<style scoped>
.term-info {
  position: relative;
  display: inline-flex;
  align-items: center;
  gap: 6px;
  max-width: 100%;
}
.term-info-heading {
  align-items: center;
}
.term-info-button {
  width: 17px;
  height: 17px;
  border: 1px solid #c8d4dd;
  border-radius: 50%;
  background: #f8fbfc;
  color: #0f7c96;
  font-size: 11px;
  font-weight: 800;
  line-height: 1;
  cursor: pointer;
  flex: 0 0 auto;
}
.term-info-button:hover,
.term-info-button[aria-expanded='true'] {
  border-color: #0f7c96;
  background: #eef7fa;
}
.term-info-popover {
  position: absolute;
  left: 0;
  top: calc(100% + 8px);
  z-index: 20;
  width: min(320px, 72vw);
  padding: 12px 14px;
  border: 1px solid #dbe5eb;
  border-radius: 8px;
  background: #fff;
  box-shadow: 0 18px 34px -22px rgba(17, 35, 48, 0.42);
  color: #394653;
  font-size: 12.5px;
  font-weight: 500;
  line-height: 1.5;
  text-transform: none;
  letter-spacing: 0;
}
</style>
