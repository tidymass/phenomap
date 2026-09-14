import { createApp } from 'vue'
import App from './App.vue'
import router from './router.js'
// Importing auth.js triggers its top-level `authReady = refreshCurrentUser()`
// exactly once; the router guard awaits that same promise.
import './auth.js'

createApp(App).use(router).mount('#app')
