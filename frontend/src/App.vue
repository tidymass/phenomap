<template>
  <div class="app">
    <header class="app-header">
      <router-link to="/" class="brand">
        <img src="/shenlab-logo.png" alt="PhenoMAP" class="brand-logo" @error="e => e.target.style.display = 'none'" />
      </router-link>
      <nav class="nav">
        <router-link to="/" class="nav-link">Home</router-link>
        <NavDropdown label="About">
          <router-link to="/about/introduction" class="dropdown-item">Introduction</router-link>
          <router-link to="/about/authors" class="dropdown-item">Authors</router-link>
          <router-link to="/about/citation" class="dropdown-item">Citation</router-link>
          <router-link to="/about/version" class="dropdown-item">Version</router-link>
          <router-link to="/about/contact" class="dropdown-item">Contact</router-link>
        </NavDropdown>

        <NavDropdown label="Analysis">
          <router-link to="/search" class="dropdown-item">Entity Search</router-link>
          <router-link to="/path" class="dropdown-item">Path Query</router-link>
          <router-link to="/enrichment" class="dropdown-item">Module Enrichment</router-link>
          <router-link to="/chat" class="dropdown-item">PhenoMAP Chat</router-link>
        </NavDropdown>

        <router-link v-if="authState.enabled && !authState.loading" to="/community" class="nav-link">Community</router-link>
        <router-link to="/download" class="nav-link">Download</router-link>
        <router-link to="/help" class="nav-link">Help</router-link>
      </nav>

      <NavDropdown v-if="authState.enabled && authState.user" :label="authState.user.display_name" align="right" avatar>
        <router-link to="/account" class="dropdown-item">Account</router-link>
        <a href="#" class="dropdown-item" @click.prevent="handleLogout">Sign out</a>
      </NavDropdown>
      <router-link v-else-if="authState.enabled && !authState.loading" to="/login" class="sign-in-link">Sign In</router-link>
    </header>
    <main :class="{ 'full-bleed': route.meta.fullBleed }">
      <router-view />
    </main>
    <AppFooter />
  </div>
</template>

<script setup>
import { useRoute, useRouter } from 'vue-router'
import NavDropdown from './components/NavDropdown.vue'
import AppFooter from './components/AppFooter.vue'
import { authState, logout } from './auth.js'

const router = useRouter()
const route = useRoute()

async function handleLogout() {
  await logout()
  router.push('/')
}
</script>

<style>
* {
  box-sizing: border-box;
}
body {
  margin: 0;
  font-family: -apple-system, 'PingFang SC', 'Helvetica Neue', Arial, sans-serif;
  background: #f7f8fa;
  color: #1b1f24;
}
.app-header {
  padding: 12px 32px;
  border-bottom: 1px solid #e2e5ea;
  background: #f7f8fa;
  display: flex;
  align-items: center;
  gap: 30px;
}
.brand {
  display: flex;
  align-items: center;
  gap: 10px;
  font-size: 23px;
  font-weight: 700;
  color: #1b1f24;
  text-decoration: none;
}
.brand-logo {
  height: 32px;
  width: auto;
}
.nav {
  display: flex;
  align-items: center;
  gap: 30px;
  flex: none;
  margin-left: auto;
}
.nav-link {
  color: #536173;
  text-decoration: none;
  font-size: 17px;
  font-weight: 700;
}
.nav-link:hover {
  color: #0f7c96;
}
.nav-link.router-link-exact-active {
  color: #0f7c96;
}
.sign-in-link {
  padding: 8px 18px;
  border-radius: 8px;
  border: 1px solid #d7dbe0;
  background: #fff;
  color: #0f7c96;
  font-weight: 700;
  font-size: 17px;
  text-decoration: none;
}
.sign-in-link:hover {
  border-color: #b9d8e0;
  background: #e9f7f9;
}
.success {
  color: #1a7f37;
}
.app {
  display: flex;
  flex-direction: column;
  min-height: 100vh;
}
main {
  flex: 1;
  max-width: 960px;
  margin: 0 auto;
  padding: 24px;
  width: 100%;
}
main.full-bleed {
  max-width: none;
  margin: 0;
  padding: 0;
}

/* Shared building blocks reused across views */
.page-title {
  margin: 0 0 4px;
}
.hint {
  color: #6b7280;
  margin-top: 0;
}
.error {
  color: #c0392b;
}
.card {
  background: #fff;
  border: 1px solid #e2e5ea;
  border-radius: 12px;
  padding: 20px;
  margin-bottom: 16px;
}
.badge {
  font-size: 11px;
  font-weight: 700;
  padding: 2px 8px;
  border-radius: 999px;
  background: #e9f7f9;
  color: #0f7c96;
  white-space: nowrap;
}
.about-page-nav {
  display: flex;
  align-items: center;
  gap: 10px;
  width: fit-content;
}
.about-next-link,
.about-prev-link {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  width: 22px;
  height: 22px;
  text-decoration: none;
  transition: color 0.16s ease;
}
.about-current-page {
  min-width: 92px;
  text-align: center;
}
.about-next-link:hover,
.about-prev-link:hover {
  color: #8fd7ea;
}
.about-next-arrow,
.about-prev-arrow {
  width: 15px;
  height: 15px;
  fill: none;
  stroke: currentColor;
  stroke-width: 2.2;
  stroke-linecap: round;
  stroke-linejoin: round;
  transition: transform 0.16s ease;
}
.about-next-link:hover .about-next-arrow {
  transform: translateX(3px);
}
.about-prev-link:hover .about-prev-arrow {
  transform: translateX(-3px);
}
</style>
