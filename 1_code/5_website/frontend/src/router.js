import { createRouter, createWebHistory } from 'vue-router'
import SearchView from './views/SearchView.vue'
import SearchPageView from './views/SearchPageView.vue'
import NodeDetailView from './views/NodeDetailView.vue'
import PathView from './views/PathView.vue'
import EnrichmentView from './views/EnrichmentView.vue'
import ChatView from './views/ChatView.vue'
import AboutIntroductionView from './views/about/IntroductionView.vue'
import AboutAuthorsView from './views/about/AuthorsView.vue'
import AboutCitationView from './views/about/CitationView.vue'
import AboutVersionView from './views/about/VersionView.vue'
import AboutContactView from './views/about/ContactView.vue'
import DownloadView from './views/DownloadView.vue'
import HelpView from './views/HelpView.vue'
import CommunityView from './views/CommunityView.vue'
import SignUpView from './views/SignUpView.vue'
import SignInView from './views/SignInView.vue'
import ForgotPasswordView from './views/ForgotPasswordView.vue'
import ResetPasswordView from './views/ResetPasswordView.vue'
import AccountView from './views/AccountView.vue'
import { authState, authReady } from './auth.js'

if (typeof window !== 'undefined' && 'scrollRestoration' in window.history) {
  window.history.scrollRestoration = 'manual'
}

const routes = [
  { path: '/', name: 'search', component: SearchView, meta: { fullBleed: true } },
  { path: '/search', name: 'search-page', component: SearchPageView, meta: { requiresAuth: true, fullBleed: true } },
  { path: '/path', name: 'path', component: PathView, meta: { requiresAuth: true, fullBleed: true } },
  { path: '/enrichment', name: 'enrichment', component: EnrichmentView, meta: { requiresAuth: true, fullBleed: true } },
  { path: '/chat', name: 'chat', component: ChatView, meta: { requiresAuth: true, fullBleed: true } },
  { path: '/about', redirect: '/about/introduction' },
  { path: '/about/introduction', name: 'about-introduction', component: AboutIntroductionView, meta: { fullBleed: true } },
  { path: '/about/authors', name: 'about-authors', component: AboutAuthorsView, meta: { fullBleed: true } },
  { path: '/about/citation', name: 'about-citation', component: AboutCitationView, meta: { fullBleed: true } },
  { path: '/about/version', name: 'about-version', component: AboutVersionView, meta: { fullBleed: true } },
  { path: '/about/contact', name: 'about-contact', component: AboutContactView, meta: { fullBleed: true } },
  { path: '/download', name: 'download', component: DownloadView, meta: { requiresAuth: true, fullBleed: true } },
  { path: '/help', redirect: '/help/get-started' },
  { path: '/help/:topic', name: 'help', component: HelpView, meta: { fullBleed: true } },
  { path: '/community', name: 'community', component: CommunityView, meta: { fullBleed: true } },
  { path: '/signup', name: 'signup', component: SignUpView, meta: { fullBleed: true } },
  { path: '/login', name: 'login', component: SignInView, meta: { fullBleed: true } },
  { path: '/forgot-password', name: 'forgot-password', component: ForgotPasswordView, meta: { fullBleed: true } },
  { path: '/reset-password', name: 'reset-password', component: ResetPasswordView, meta: { fullBleed: true } },
  { path: '/account', name: 'account', component: AccountView, meta: { fullBleed: true } },
  { path: '/node/:label/:id', name: 'node-detail', component: NodeDetailView, props: true, meta: { fullBleed: true } },
]

const router = createRouter({
  history: createWebHistory(),
  routes,
  scrollBehavior(to) {
    if (to.hash) {
      return { el: to.hash, behavior: 'smooth' }
    }
    return { top: 0 }
  },
})

router.beforeEach(async (to) => {
  if (!to.meta.requiresAuth) return true
  if (authState.loading) await authReady
  if (!authState.user) {
    return { path: '/login', query: { redirect: to.fullPath } }
  }
  return true
})

export default router
