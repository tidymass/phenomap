<template>
  <div class="dropdown" ref="containerRef">
    <button
      class="dropdown-trigger"
      :class="{ open, 'with-avatar': avatar }"
      :aria-label="avatar ? label : undefined"
      @click="toggle"
    >
      <template v-if="avatar">
        <span class="avatar-badge">{{ initials }}</span>
      </template>
      <template v-else>
        {{ label }} <span class="caret">&#9662;</span>
      </template>
    </button>
    <div v-if="open" class="dropdown-menu" :class="{ 'align-right': align === 'right' }" @click="close">
      <slot />
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'

const props = defineProps({
  label: { type: String, required: true },
  align: { type: String, default: 'left' }, // 'left' or 'right' -- which edge the menu hangs from
  avatar: { type: Boolean, default: false }, // show an initials badge before the label
})

const initials = computed(() => {
  const parts = props.label.trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return '?'
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase()
  return (parts[0][0] + parts[1][0]).toUpperCase()
})

const open = ref(false)
const containerRef = ref(null)

function toggle() {
  open.value = !open.value
}
function close() {
  open.value = false
}
function handleClickOutside(e) {
  if (containerRef.value && !containerRef.value.contains(e.target)) {
    close()
  }
}

onMounted(() => document.addEventListener('click', handleClickOutside))
onUnmounted(() => document.removeEventListener('click', handleClickOutside))
</script>

<style scoped>
.dropdown {
  position: relative;
}
.dropdown-trigger {
  background: none;
  border: none;
  font: inherit;
  color: #536173;
  font-weight: 700;
  font-size: 17px;
  cursor: pointer;
  padding: 4px 0;
  display: flex;
  align-items: center;
  gap: 4px;
}
.dropdown-trigger.open,
.dropdown-trigger:hover {
  color: #0f7c96;
}
.dropdown-trigger.with-avatar {
  padding: 0;
}
.avatar-badge {
  width: 42px;
  height: 42px;
  border-radius: 50%;
  background: linear-gradient(135deg, #3949ab, #5b6fd8);
  color: #fff;
  font-size: 15px;
  font-weight: 700;
  letter-spacing: 0.02em;
  display: flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  transition: transform 0.12s ease, box-shadow 0.12s ease;
}
.dropdown-trigger.with-avatar:hover .avatar-badge,
.dropdown-trigger.with-avatar.open .avatar-badge {
  transform: scale(1.06);
  box-shadow: 0 0 0 3px rgba(57, 73, 171, 0.18);
}
.caret {
  font-size: 11px;
}
.dropdown-menu {
  position: absolute;
  top: 100%;
  left: 0;
  margin-top: 10px;
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 10px;
  padding: 6px;
  min-width: 0;
  width: max-content;
  box-shadow: 0 8px 24px rgba(0, 0, 0, 0.08);
  z-index: 20;
  display: flex;
  flex-direction: column;
}
.dropdown-menu.align-right {
  left: 50%;
  right: auto;
  transform: translateX(-50%);
}
.dropdown-menu :deep(a),
.dropdown-menu :deep(.dropdown-item) {
  display: block;
  width: max-content;
  padding: 10px 12px;
  border-radius: 6px;
  color: #1b1f24;
  text-decoration: none;
  font-size: 16px;
  font-weight: 650;
  white-space: nowrap;
}
.dropdown-menu :deep(a:hover) {
  background: #f7f8fa;
}
.dropdown-menu :deep(.dropdown-item.disabled) {
  color: #b0b5bd;
  cursor: default;
}
</style>
