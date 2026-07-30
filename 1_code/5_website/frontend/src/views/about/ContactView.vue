<template>
  <div class="contact-page">
    <section class="contact-hero">
      <div class="contact-hero-inner">
        <nav class="about-page-nav" aria-label="About page navigation">
          <router-link to="/about/version" class="eyebrow about-prev-link" aria-label="Previous About page: Version">
            <svg class="about-prev-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 12H5" />
              <path d="m11 6-6 6 6 6" />
            </svg>
          </router-link>
          <span class="eyebrow about-current-page">Contact</span>
          <router-link to="/about/introduction" class="eyebrow about-next-link" aria-label="Next About page: Introduction">
            <svg class="about-next-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 12h14" />
              <path d="m13 6 6 6-6 6" />
            </svg>
          </router-link>
        </nav>
        <h1>Contact Us</h1>
        <p>{{ facts.contact.intro }}</p>
      </div>
    </section>

    <section class="contact-body">
      <div class="contact-layout">
        <div class="contact-main">
          <section class="map-section" aria-label="Map">
            <div class="map-embed">
              <iframe
                :src="mapEmbedUrl"
                title="Map to the Experimental Medicine Building, 59 Nanyang Drive, Singapore 636921"
                loading="lazy"
                referrerpolicy="no-referrer-when-downgrade"
              ></iframe>
            </div>
          </section>
        </div>

        <aside class="send-message" aria-label="Send a message">
          <p class="section-kicker">Send a Message</p>
          <h2>Tell Us What You Need.</h2>
          <p class="form-intro">{{ facts.contact.form_intro }}</p>
          <form @submit.prevent="submit">
            <label>
              Full name
              <input v-model="name" type="text" placeholder="Jane Doe" required />
            </label>
            <label>
              Email address
              <input v-model="email" type="email" placeholder="name@example.com" required />
            </label>
            <label>
              Message
              <textarea v-model="message" rows="6" placeholder="How can we help?" required></textarea>
            </label>

            <p v-if="error" class="error">{{ error }}</p>
            <p v-if="sent" class="success">Message sent -- thanks for reaching out.</p>

            <button type="submit" :disabled="sending">{{ sending ? 'Sending...' : 'Send message' }}</button>
          </form>
        </aside>
      </div>
    </section>
  </div>
</template>

<script setup>
import { computed, ref } from 'vue'
import { submitContact } from '../../api.js'
// Single source of truth: see product_facts.json's _comment.
import facts from '../../data/product_facts.json'

const address = facts.contact.address
// hl=en forces the embed to render in English regardless of the visitor's
// browser locale or IP-based geolocation (Google Maps otherwise infers a
// language, which was showing up as Chinese for users routed near Singapore).
const mapEmbedUrl = computed(() => `https://maps.google.com/maps?q=${encodeURIComponent(address)}&hl=en&output=embed`)

const name = ref('')
const email = ref('')
const message = ref('')
const sending = ref(false)
const sent = ref(false)
const error = ref('')

async function submit() {
  sending.value = true
  error.value = ''
  sent.value = false
  try {
    await submitContact({ name: name.value, email: email.value, message: message.value })
    sent.value = true
    name.value = ''
    email.value = ''
    message.value = ''
  } catch (e) {
    error.value = e.message
  } finally {
    sending.value = false
  }
}
</script>

<style scoped>
.contact-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #1b1f24;
}
.contact-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}
.contact-hero-inner {
  max-width: 1200px;
  margin: 0 auto;
  padding: 34px 40px 32px;
}
.eyebrow,
.section-kicker {
  margin: 0;
  color: #0f7c96;
  font-size: 12.5px;
  font-weight: 800;
  letter-spacing: 0.08em;
  text-transform: uppercase;
}
.contact-hero .eyebrow {
  color: #8fd7ea;
}
.contact-hero h1 {
  max-width: 720px;
  margin: 12px 0 8px;
  color: #ffffff;
  font-size: clamp(32px, 3vw, 40px);
  font-weight: 850;
  line-height: 1.06;
  letter-spacing: 0;
}
.contact-hero p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 16px;
  line-height: 1.62;
  font-weight: 600;
  overflow-wrap: break-word;
}
.contact-body {
  max-width: 1200px;
  margin: 0 auto;
  padding: 44px 40px 88px;
}
.contact-layout {
  display: grid;
  grid-template-columns: minmax(0, 1.08fr) minmax(360px, 0.72fr);
  gap: 36px;
  align-items: stretch;
}
.contact-main {
  display: grid;
  gap: 28px;
  min-width: 0;
  height: 100%;
}
.send-message,
.map-section {
  min-width: 0;
}
.map-section {
  overflow: hidden;
  border: 1px solid #e2e5ea;
  border-top: 3px solid #8fd7ea;
  border-radius: 0;
  background: #ffffff;
  height: 100%;
}
.map-embed {
  overflow: hidden;
  height: 100%;
}
.map-embed iframe {
  display: block;
  width: 100%;
  height: 100%;
  min-height: 0;
  border: 0;
}
.send-message {
  position: sticky;
  top: 92px;
  background: #fff;
  border: 1px solid #e3ebef;
  border-top: 3px solid #8fd7ea;
  border-radius: 0;
  padding: 32px;
}
.send-message h2 {
  margin: 10px 0 8px;
  color: #111827;
  font-size: 30px;
  font-weight: 850;
  letter-spacing: 0;
}
.form-intro {
  margin: 0 0 24px;
  color: #667085;
  font-size: 14.5px;
  line-height: 1.6;
  font-weight: 600;
}
.send-message form {
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.send-message label {
  display: flex;
  flex-direction: column;
  gap: 8px;
  color: #55607a;
  font-size: 13px;
  font-weight: 800;
}
.send-message input,
.send-message textarea {
  font: inherit;
  font-size: 15px;
  font-weight: 600;
  padding: 12px 13px;
  border-radius: 8px;
  border: 1px solid #d8e5ea;
  background: #fbfdfe;
  color: #1b1f24;
  resize: vertical;
  transition: border-color 0.16s ease, box-shadow 0.16s ease, background 0.16s ease;
}
.send-message input:focus,
.send-message textarea:focus {
  outline: none;
  border-color: #0f7c96;
  background: #ffffff;
  box-shadow: 0 0 0 3px rgba(15, 124, 150, 0.12);
}
.send-message button {
  width: 100%;
  margin-top: 2px;
  padding: 13px 18px;
  border-radius: 8px;
  border: none;
  background: #0f7c96;
  color: #fff;
  font-weight: 800;
  font-size: 15px;
  cursor: pointer;
  transition: background 0.16s ease, transform 0.16s ease;
}
.send-message button:hover:not(:disabled) {
  background: #245c7e;
  transform: translateY(-1px);
}
.send-message button:disabled {
  background: #a8c6cf;
  cursor: not-allowed;
  transform: none;
}
.success {
  color: #1a7f37;
  font-size: 15px;
  margin: 0;
  font-weight: 700;
}
.error {
  color: #b42318;
  font-size: 15px;
  margin: 0;
  font-weight: 700;
}

@media (max-width: 980px) {
  .contact-layout {
    grid-template-columns: 1fr;
  }
  .contact-main,
  .map-section,
  .map-embed {
    height: auto;
  }
  .map-embed iframe {
    height: 430px;
  }
  .send-message {
    position: static;
  }
}

@media (max-width: 720px) {
  .contact-hero-inner {
    padding: 28px 24px 26px;
  }
  .contact-hero h1 {
    font-size: 30px;
  }
  .contact-hero p:not(.eyebrow) {
    font-size: 15.5px;
  }
  .contact-body {
    padding: 28px 20px 56px;
  }
  .send-message {
    padding: 24px 22px;
  }
  .send-message h2 {
    font-size: 22px;
  }
  .map-embed iframe {
    height: 420px;
  }
}
</style>
