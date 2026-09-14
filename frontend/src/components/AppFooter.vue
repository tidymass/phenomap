<template>
  <footer class="app-footer">
    <div class="footer-inner">
      <div class="footer-col footer-brand">
        <router-link to="/" class="footer-logo">
          <img src="/shenlab-logo-omics.png" alt="PhenoMAP" @error="e => e.target.style.display = 'none'" />
        </router-link>
      </div>

      <nav class="footer-col footer-links">
        <router-link to="/">Home</router-link>
        <router-link to="/about/introduction">About</router-link>
        <router-link to="/community">Community</router-link>
        <router-link to="/download">Download</router-link>
      </nav>

      <nav class="footer-col footer-links">
        <router-link to="/help">Help</router-link>
        <router-link to="/about/contact">Contact Us</router-link>
        <a href="https://github.com/tidymass/phenomap" target="_blank" rel="noopener">GitHub</a>
        <a href="#top" class="footer-back-to-top" @click.prevent="scrollTop">Back to top &uarr;</a>
      </nav>

      <div class="footer-col footer-meta">
        <p class="footer-wordmark">PhenoMAP</p>
        <p>&copy; {{ year }} Shen Lab. All rights reserved.</p>
        <p>Last updated {{ lastUpdated }}</p>
        <p>Version <span class="footer-version">v1.0</span></p>
      </div>
    </div>
  </footer>
</template>

<script setup>
const year = new Date().getFullYear()
const lastUpdated = '2026-07-31'

function scrollTop() {
  window.scrollTo({ top: 0, behavior: 'smooth' })
}
</script>

<style scoped>
.app-footer {
  margin-top: auto;
  border-top: 1px solid #dfe3ee;
  background: #eef0f6;
}
.footer-inner {
  max-width: 1100px;
  margin: 0 auto;
  padding: 40px 28px 34px;
  display: flex;
  flex-wrap: wrap;
  align-items: flex-start;
  gap: 56px;
  box-sizing: border-box;
}
.footer-col {
  display: flex;
  flex-direction: column;
  gap: 10px;
}
.footer-logo {
  display: block;
  width: fit-content;
}
.footer-logo img {
  height: 100px;
  width: auto;
  display: block;
}
.footer-links {
  min-width: 130px;
  margin-left: 24px;
}
.footer-links a {
  color: #55607a;
  font-size: 14px;
  font-weight: 500;
  text-decoration: none;
}
.footer-links a:hover {
  color: #3949ab;
  text-decoration: underline;
}
.footer-back-to-top {
  margin-top: 2px;
}
.footer-meta {
  margin-left: auto;
  text-align: right;
  color: #7a8296;
  font-size: 13px;
  line-height: 1.6;
}
.footer-meta p {
  margin: 0;
}
.footer-wordmark {
  color: #293247;
  font-size: 15px;
  font-weight: 800;
  letter-spacing: 0.02em;
}
.footer-version {
  font-weight: 700;
  color: #55607a;
}

@media (max-width: 720px) {
  .footer-inner {
    padding: 28px 20px 24px;
    gap: 24px;
  }
  .footer-meta {
    margin-left: 0;
    text-align: left;
  }
}
</style>
