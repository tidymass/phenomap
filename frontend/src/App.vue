<template>
  <div class="app">
    <header class="app-header" :class="{ 'nav-open': navOpen }">
      <router-link to="/" class="brand">
        <img src="/shenlab-logo.png" alt="PhenoMAP" class="brand-logo" @error="e => e.target.style.display = 'none'" />
      </router-link>
      <nav class="nav" id="main-nav" @click="onNavClick">
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

      <!-- Only shown on narrow screens (see the @media block below); on
           desktop this button is display:none and the nav is unchanged. -->
      <button
        type="button"
        class="menu-toggle"
        :aria-expanded="navOpen ? 'true' : 'false'"
        aria-controls="main-nav"
        aria-label="Menu"
        @click="navOpen = !navOpen"
      >
        <span class="menu-toggle-bar"></span>
        <span class="menu-toggle-bar"></span>
        <span class="menu-toggle-bar"></span>
      </button>
    </header>
    <main :class="{ 'full-bleed': route.meta.fullBleed }">
      <router-view />
    </main>
    <AppFooter />
  </div>
</template>

<script setup>
import { ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import NavDropdown from './components/NavDropdown.vue'
import AppFooter from './components/AppFooter.vue'
import { authState, logout } from './auth.js'

const router = useRouter()
const route = useRoute()

// Mobile nav panel. Closed whenever the route changes or a link inside it
// is tapped, so it never lingers over the page you just opened.
const navOpen = ref(false)
watch(() => route.fullPath, () => { navOpen.value = false })
function onNavClick(e) {
  if (e.target.closest('a')) navOpen.value = false
}

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
/* ---- Narrow screens: collapse the nav into a hamburger panel ----
   Everything below only applies under 900px wide, so the desktop
   header keeps exactly the layout above. */
.menu-toggle {
  display: none;
}
@media (max-width: 900px) {
  .app-header {
    position: relative;
    padding: 10px 16px;
    gap: 12px;
    z-index: 50;
  }
  .brand {
    margin-right: auto;
  }
  .brand-logo {
    height: 28px;
  }
  .sign-in-link {
    padding: 7px 14px;
    font-size: 15px;
  }
  .app-header .avatar-badge {
    width: 36px;
    height: 36px;
    font-size: 13px;
  }
  .menu-toggle {
    display: inline-flex;
    flex-direction: column;
    justify-content: center;
    gap: 5px;
    width: 40px;
    height: 40px;
    padding: 0 9px;
    border: 1px solid #d7dbe0;
    border-radius: 8px;
    background: #fff;
    cursor: pointer;
    flex: none;
  }
  .menu-toggle-bar {
    display: block;
    height: 2px;
    width: 100%;
    border-radius: 2px;
    background: #536173;
    transition: transform 0.18s ease, opacity 0.18s ease;
  }
  .nav-open .menu-toggle-bar:nth-child(1) {
    transform: translateY(7px) rotate(45deg);
  }
  .nav-open .menu-toggle-bar:nth-child(2) {
    opacity: 0;
  }
  .nav-open .menu-toggle-bar:nth-child(3) {
    transform: translateY(-7px) rotate(-45deg);
  }

  /* The nav becomes a full-width panel that drops down under the header */
  .app-header .nav {
    display: none;
    position: absolute;
    top: 100%;
    left: 0;
    right: 0;
    margin: 0;
    padding: 8px 16px 16px;
    flex-direction: column;
    align-items: stretch;
    gap: 0;
    background: #f7f8fa;
    border-bottom: 1px solid #e2e5ea;
    box-shadow: 0 12px 24px rgba(15, 23, 42, 0.08);
    max-height: calc(100vh - 60px);
    overflow-y: auto;
  }
  .app-header.nav-open .nav {
    display: flex;
  }
  .app-header .nav > .nav-link,
  .app-header .nav > .dropdown > .dropdown-trigger {
    width: 100%;
    padding: 13px 4px;
    font-size: 17px;
    border-bottom: 1px solid #e8ebef;
    justify-content: space-between;
  }
  .app-header .nav > :last-child,
  .app-header .nav > :last-child > .dropdown-trigger {
    border-bottom: none;
  }
  /* Sub-menus (About / Analysis) open inline inside the panel */
  .app-header .nav .dropdown-menu {
    position: static;
    margin: 0 0 6px;
    padding: 2px 0 2px 10px;
    width: 100%;
    border: none;
    border-radius: 0;
    box-shadow: none;
    background: transparent;
  }
  .app-header .nav .dropdown-menu .dropdown-item {
    width: 100%;
    padding: 11px 12px;
    font-size: 16px;
    color: #374151;
  }
  /* Account menu next to the avatar: keep it on-screen at the right edge */
  .app-header > .dropdown .dropdown-menu.align-right {
    left: auto;
    right: 0;
    transform: none;
  }
}
</style>
