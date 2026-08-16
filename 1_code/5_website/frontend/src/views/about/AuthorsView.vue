<template>
  <div class="authors-page">
    <section class="authors-hero">
      <div class="authors-hero-inner">
        <nav class="about-page-nav" aria-label="About page navigation">
          <router-link to="/about/introduction" class="eyebrow about-prev-link" aria-label="Previous About page: Introduction">
            <svg class="about-prev-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M19 12H5" />
              <path d="m11 6-6 6 6 6" />
            </svg>
          </router-link>
          <span class="eyebrow about-current-page">Authors</span>
          <router-link to="/about/citation" class="eyebrow about-next-link" aria-label="Next About page: Citation">
            <svg class="about-next-arrow" viewBox="0 0 24 24" aria-hidden="true">
              <path d="M5 12h14" />
              <path d="m13 6 6 6-6 6" />
            </svg>
          </router-link>
        </nav>
        <h1>Project Team</h1>
        <p>{{ facts.authors.intro }}</p>
      </div>
    </section>

    <section class="authors-body">
      <section class="author-section faculty-section">
        <div class="section-head">
          <p class="section-kicker">Faculty</p>
          <h2>Principal Investigators</h2>
        </div>

        <div class="faculty-grid">
          <article v-for="a in faculty" :key="a.slug" class="faculty-card">
            <div class="faculty-photo">
              <img
                v-if="!broken.has(a.slug)"
                :src="`/authors/${a.slug}.jpg`"
                :alt="a.name"
                @error="broken.add(a.slug)"
              />
              <span v-else class="author-initials">{{ initials(a.name) }}</span>
            </div>
            <div class="author-copy">
              <h3>{{ a.name }}</h3>
              <p>{{ a.role }}</p>
              <a :href="`mailto:${a.email}`" class="email-link" :aria-label="`Email ${a.name}`">
                <svg class="email-icon" viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M4.5 6.75h15v10.5h-15z" />
                  <path d="m5.25 7.5 6.75 5.25 6.75-5.25" />
                </svg>
                <span>{{ a.email }}</span>
              </a>
            </div>
          </article>
        </div>
      </section>

      <section class="author-section">
        <div class="section-head">
          <p class="section-kicker">Students</p>
          <h2>Research Contributors</h2>
        </div>

        <div class="student-grid">
          <article v-for="a in students" :key="a.slug" class="student-card">
            <div class="student-photo">
              <img
                v-if="!broken.has(a.slug)"
                :src="`/authors/${a.slug}.jpg`"
                :alt="a.name"
                @error="broken.add(a.slug)"
              />
              <span v-else class="author-initials">{{ initials(a.name) }}</span>
            </div>
            <div class="author-copy">
              <h3>{{ a.name }}</h3>
              <p>{{ a.role }}</p>
              <a :href="`mailto:${a.email}`" class="email-link" :aria-label="`Email ${a.name}`">
                <svg class="email-icon" viewBox="0 0 24 24" aria-hidden="true">
                  <path d="M4.5 6.75h15v10.5h-15z" />
                  <path d="m5.25 7.5 6.75 5.25 6.75-5.25" />
                </svg>
                <span>{{ a.email }}</span>
              </a>
            </div>
          </article>
        </div>
      </section>
    </section>
  </div>
</template>

<script setup>
import { reactive } from 'vue'
// Single source of truth: see product_facts.json's _comment for why this
// file (not a local const list) is where author info lives.
import facts from '../../data/product_facts.json'

const faculty = facts.authors.faculty
const students = facts.authors.students

const broken = reactive(new Set())

function initials(name) {
  return name
    .split(' ')
    .filter(Boolean)
    .map((p) => p[0])
    .slice(0, 2)
    .join('')
    .toUpperCase()
}
</script>

<style scoped>
.authors-page {
  min-height: calc(100vh - 69px);
  overflow-x: hidden;
  background: #f7f8fa;
  color: #1b1f24;
}
.authors-hero {
  background:
    radial-gradient(circle at 16% 18%, rgba(143, 215, 234, 0.3), transparent 28%),
    radial-gradient(circle at 82% 18%, rgba(79, 181, 155, 0.18), transparent 30%),
    linear-gradient(135deg, #1d5876 0%, #2d7895 52%, #245f7d 100%);
  border-bottom: 0;
}
.authors-hero-inner {
  max-width: none;
  margin: 0 auto;
  padding: 34px 40px 32px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
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
.authors-hero .eyebrow {
  color: #8fd7ea;
}
.authors-hero h1 {
  max-width: 720px;
  margin: 12px 0 8px;
  color: #ffffff;
  font-size: clamp(32px, 3vw, 40px);
  font-weight: 850;
  line-height: 1.06;
  letter-spacing: 0;
}
.authors-hero p:not(.eyebrow) {
  max-width: 1100px;
  margin: 0;
  color: #d8e7ef;
  font-size: 16px;
  line-height: 1.62;
  font-weight: 600;
  overflow-wrap: break-word;
}
.authors-body {
  max-width: none;
  margin: 0 auto;
  padding: 44px 40px 88px;
  width: min(90vw, 1680px);
  box-sizing: border-box;
}
.author-section + .author-section {
  margin-top: 56px;
}
.section-head {
  display: flex;
  align-items: flex-start;
  flex-direction: column;
  gap: 8px;
  margin-bottom: 20px;
  padding-bottom: 16px;
  border-bottom: 1px solid #e3ebef;
}
.section-head h2 {
  margin: 8px 0 0;
  color: #111827;
  font-size: 30px;
  font-weight: 850;
  line-height: 1.12;
  letter-spacing: 0;
}
.faculty-grid {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 28px;
}
.faculty-card {
  display: grid;
  grid-template-columns: 190px 1fr;
  gap: 26px;
  align-items: center;
  min-width: 0;
  padding: 24px;
  border: 1px solid #e3ebef;
  border-top: 3px solid #8fd7ea;
  border-radius: 0;
  background: #ffffff;
}
.faculty-photo {
  width: 190px;
  aspect-ratio: 1;
  border-radius: 8px;
  overflow: hidden;
  background: #e9f7f9;
}
.faculty-photo img,
.student-photo img {
  width: 100%;
  height: 100%;
  display: block;
  object-fit: cover;
}
.student-grid {
  display: grid;
  grid-template-columns: repeat(4, minmax(0, 1fr));
  gap: 20px;
}
.student-card {
  min-width: 0;
  padding: 20px;
  border: 1px solid #e3ebef;
  border-top: 3px solid #8fd7ea;
  border-radius: 0;
  background: #ffffff;
}
.student-photo {
  width: 100%;
  aspect-ratio: 1;
  margin-bottom: 18px;
  border-radius: 8px;
  overflow: hidden;
  background: #e9f7f9;
}
.author-initials {
  width: 100%;
  height: 100%;
  display: grid;
  place-items: center;
  background: #0f7c96;
  color: #fff;
  font-size: 38px;
  font-weight: 850;
  letter-spacing: 0;
}
.author-copy {
  min-width: 0;
}
.author-copy h3 {
  margin: 0 0 8px;
  color: #111827;
  font-size: 21px;
  font-weight: 850;
  line-height: 1.18;
  letter-spacing: 0;
}
.student-card .author-copy h3 {
  font-size: 17px;
}
.faculty-card .author-copy p {
  margin: 0 0 14px;
  color: #667085;
  font-size: 14.5px;
  font-weight: 600;
  line-height: 1.5;
}
.student-card .author-copy p {
  margin: 0 0 14px;
  color: #667085;
  font-size: 13px;
  font-weight: 600;
  line-height: 1.5;
}
.email-link {
  display: inline-flex;
  align-items: center;
  gap: 7px;
  max-width: 100%;
  color: #0f7c96;
  font-size: 13px;
  font-weight: 800;
  line-height: 1.35;
  text-decoration: none;
  overflow-wrap: anywhere;
}
.email-link:hover {
  color: #245c7e;
}
.email-icon {
  width: 14px;
  height: 14px;
  flex: 0 0 auto;
  fill: none;
  stroke: currentColor;
  stroke-width: 1.9;
  stroke-linecap: round;
  stroke-linejoin: round;
}
.email-link span {
  min-width: 0;
  overflow-wrap: anywhere;
}

@media (max-width: 1080px) {
  .faculty-grid,
  .student-grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
  .faculty-card {
    grid-template-columns: 150px 1fr;
  }
  .faculty-photo {
    width: 150px;
  }
}

@media (max-width: 720px) {
  .authors-hero-inner {
    padding: 28px 24px 26px;
  }
  .authors-hero h1 {
    font-size: 30px;
  }
  .authors-hero p:not(.eyebrow) {
    max-width: 330px;
    font-size: 15.5px;
  }
  .authors-body {
    padding: 28px 20px 56px;
  }
  .section-head {
    align-items: flex-start;
    flex-direction: column;
    gap: 8px;
  }
  .section-head h2 {
    font-size: 24px;
  }
  .faculty-grid,
  .student-grid {
    grid-template-columns: 1fr;
  }
  .faculty-card {
    grid-template-columns: 112px 1fr;
    gap: 16px;
    padding: 18px;
  }
  .faculty-photo {
    width: 112px;
    border-radius: 8px;
  }
  .student-card {
    display: grid;
    grid-template-columns: 84px 1fr;
    gap: 16px;
    align-items: center;
    padding: 18px;
  }
  .student-photo {
    width: 84px;
    margin-bottom: 0;
    border-radius: 12px;
  }
  .author-copy h3,
  .student-card .author-copy h3 {
    font-size: 16px;
  }
  .faculty-card .author-copy p,
  .student-card .author-copy p {
    max-width: 180px;
    font-size: 12.5px;
  }
}
</style>
