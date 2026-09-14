<template>
  <div class="country-combobox" :class="{ 'with-icon': withIcon }">
    <svg
      v-if="withIcon"
      class="country-icon"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      aria-hidden="true"
    >
      <circle cx="12" cy="12" r="9" />
      <path d="M3 12h18M12 3c2.5 2.6 3.7 5.6 3.7 9s-1.2 6.4-3.7 9M12 3c-2.5 2.6-3.7 5.6-3.7 9s1.2 6.4 3.7 9" />
    </svg>
    <input
      :value="query"
      type="text"
      required
      autocomplete="country-name"
      class="country-input"
      role="combobox"
      aria-autocomplete="list"
      :aria-expanded="open && suggestions.length > 0"
      @input="handleInput"
      @focus="open = true"
      @blur="handleBlur"
      @keydown.down.prevent="moveActive(1)"
      @keydown.up.prevent="moveActive(-1)"
      @keydown.enter.prevent="selectActive"
      @keydown.esc="open = false"
    />

    <div v-if="open && suggestions.length" class="country-menu" role="listbox">
      <button
        v-for="(country, index) in suggestions"
        :key="country.code"
        type="button"
        class="country-option"
        :class="{ active: index === activeIndex }"
        role="option"
        @mousedown.prevent="selectCountry(country)"
      >
        <span>{{ country.name }}</span>
      </button>
    </div>
  </div>
</template>

<script setup>
import { computed, ref, watch } from 'vue'
import { normalizeCountry, searchCountries } from '../lib/countries.js'

const props = defineProps({
  modelValue: {
    type: String,
    default: '',
  },
  withIcon: {
    type: Boolean,
    default: false,
  },
})

const emit = defineEmits(['update:modelValue'])

const query = ref(props.modelValue)
const open = ref(false)
const activeIndex = ref(0)

const suggestions = computed(() => searchCountries(query.value))

watch(
  () => props.modelValue,
  (value) => {
    if (value !== query.value) query.value = value
  },
)

function handleInput(event) {
  query.value = event.target.value
  emit('update:modelValue', '')
  activeIndex.value = 0
  open.value = true
}

function selectCountry(country) {
  query.value = country.name
  emit('update:modelValue', country.name)
  open.value = false
}

function moveActive(delta) {
  if (!open.value) open.value = true
  if (!suggestions.value.length) return
  activeIndex.value = (activeIndex.value + delta + suggestions.value.length) % suggestions.value.length
}

function selectActive() {
  const country = suggestions.value[activeIndex.value]
  if (country) selectCountry(country)
}

function handleBlur() {
  const normalized = normalizeCountry(query.value)
  if (normalized) {
    query.value = normalized
    emit('update:modelValue', normalized)
  } else if (props.modelValue) {
    query.value = props.modelValue
  }
  open.value = false
}
</script>

<style scoped>
.country-combobox {
  position: relative;
  width: 100%;
}
.country-input {
  width: 100%;
}
.with-icon .country-input {
  padding-left: 40px;
}
.country-icon {
  position: absolute;
  z-index: 1;
  left: 13px;
  top: 50%;
  width: 18px;
  height: 18px;
  color: #9aa1c2;
  pointer-events: none;
  transform: translateY(-50%);
}
.country-menu {
  position: absolute;
  z-index: 20;
  top: calc(100% + 6px);
  left: 0;
  right: 0;
  max-height: 230px;
  overflow-y: auto;
  padding: 6px;
  border: 1px solid #d9deea;
  border-radius: 10px;
  background: #ffffff;
  box-shadow: 0 18px 36px -22px rgba(17, 24, 60, 0.4);
}
.country-option {
  width: 100%;
  display: flex;
  align-items: center;
  padding: 9px 10px;
  border: 0;
  border-radius: 8px;
  background: transparent;
  color: #263247;
  cursor: pointer;
  font: inherit;
  text-align: left;
}
.country-option:hover,
.country-option.active {
  background: #eef1ff;
  color: #3949ab;
}
.country-option span {
  font-size: 14px;
  font-weight: 700;
}
</style>
