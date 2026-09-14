<template>
  <div ref="containerRef" class="hologram-container"></div>
</template>

<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import * as THREE from 'three'

const containerRef = ref(null)
const CYAN = 0x22d3ee

let renderer, scene, camera, group, scanline, animationId, resizeObserver

function addPart(group, geo, x, y, z, rx, ry, rz, wireMat, glowMat) {
  const mesh = new THREE.Mesh(geo, wireMat)
  mesh.position.set(x, y, z)
  mesh.rotation.set(rx || 0, ry || 0, rz || 0)
  group.add(mesh)

  const glow = new THREE.Mesh(geo, glowMat)
  glow.position.copy(mesh.position)
  glow.rotation.copy(mesh.rotation)
  glow.scale.setScalar(1.15)
  group.add(glow)
}

// A stylized, low-poly wireframe figure -- not an anatomical model, just
// enough primitive shapes arranged human-like to read as a "hologram" at
// a glance, in keeping with the site's line/dot graph visual language.
function buildFigure() {
  const g = new THREE.Group()
  const wireMat = new THREE.MeshBasicMaterial({
    color: CYAN,
    wireframe: true,
    transparent: true,
    opacity: 0.85,
  })
  const glowMat = new THREE.MeshBasicMaterial({
    color: CYAN,
    wireframe: true,
    transparent: true,
    opacity: 0.16,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  })

  const P = (geo, x, y, z, rx, ry, rz) => addPart(g, geo, x, y, z, rx, ry, rz, wireMat, glowMat)

  P(new THREE.IcosahedronGeometry(0.5, 1), 0, 2.55, 0)
  P(new THREE.CylinderGeometry(0.14, 0.16, 0.25, 8), 0, 2.15, 0)
  P(new THREE.CylinderGeometry(0.55, 0.4, 1.5, 10), 0, 1.35, 0)
  P(new THREE.CylinderGeometry(0.42, 0.32, 0.4, 10), 0, 0.5, 0)
  P(new THREE.CylinderGeometry(0.14, 0.12, 0.85, 8), -0.75, 1.65, 0, 0, 0, 0.35)
  P(new THREE.CylinderGeometry(0.14, 0.12, 0.85, 8), 0.75, 1.65, 0, 0, 0, -0.35)
  P(new THREE.CylinderGeometry(0.11, 0.09, 0.75, 8), -1.25, 0.95, 0, 0, 0, 0.55)
  P(new THREE.CylinderGeometry(0.11, 0.09, 0.75, 8), 1.25, 0.95, 0, 0, 0, -0.55)
  P(new THREE.CylinderGeometry(0.2, 0.16, 1.05, 8), -0.28, -0.55, 0, 0, 0, 0.06)
  P(new THREE.CylinderGeometry(0.2, 0.16, 1.05, 8), 0.28, -0.55, 0, 0, 0, -0.06)
  P(new THREE.CylinderGeometry(0.15, 0.11, 1.0, 8), -0.32, -1.6, 0, 0, 0, 0.03)
  P(new THREE.CylinderGeometry(0.15, 0.11, 1.0, 8), 0.32, -1.6, 0, 0, 0, -0.03)

  return g
}

function buildBase() {
  const g = new THREE.Group()
  const ringMat = new THREE.MeshBasicMaterial({
    color: CYAN,
    transparent: true,
    opacity: 0.55,
    side: THREE.DoubleSide,
  })
  const ring = new THREE.Mesh(new THREE.RingGeometry(1.15, 1.25, 48), ringMat)
  ring.rotation.x = -Math.PI / 2
  ring.position.y = -2.15
  g.add(ring)

  const ring2Mat = new THREE.MeshBasicMaterial({
    color: CYAN,
    transparent: true,
    opacity: 0.22,
    side: THREE.DoubleSide,
  })
  const ring2 = new THREE.Mesh(new THREE.RingGeometry(0.7, 0.78, 48), ring2Mat)
  ring2.rotation.x = -Math.PI / 2
  ring2.position.y = -2.15
  g.add(ring2)

  return g
}

function handleResize() {
  const el = containerRef.value
  if (!el || !renderer || !camera) return
  const w = el.clientWidth
  const h = el.clientHeight
  if (w === 0 || h === 0) return
  camera.aspect = w / h
  camera.updateProjectionMatrix()
  renderer.setSize(w, h)
}

onMounted(() => {
  const el = containerRef.value
  const width = el.clientWidth || 1
  const height = el.clientHeight || 1

  scene = new THREE.Scene()
  camera = new THREE.PerspectiveCamera(38, width / height, 0.1, 100)
  camera.position.set(0, 0.3, 7)
  camera.lookAt(0, 0.3, 0)

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  renderer.setSize(width, height)
  el.appendChild(renderer.domElement)

  group = new THREE.Group()
  group.add(buildFigure())
  group.add(buildBase())
  scene.add(group)

  const scanMat = new THREE.MeshBasicMaterial({
    color: 0x8fe9f5,
    transparent: true,
    opacity: 0.3,
    blending: THREE.AdditiveBlending,
    side: THREE.DoubleSide,
    depthWrite: false,
  })
  scanline = new THREE.Mesh(new THREE.PlaneGeometry(2.6, 0.035), scanMat)
  scanline.position.y = -2.1
  scene.add(scanline)

  let t = 0
  function animate() {
    t += 0.012
    group.rotation.y += 0.006
    scanline.position.y = -2.1 + ((Math.sin(t * 0.6) + 1) / 2) * 4.7
    scanline.material.opacity = 0.22 + Math.random() * 0.14
    renderer.render(scene, camera)
    animationId = requestAnimationFrame(animate)
  }
  animate()

  resizeObserver = new ResizeObserver(handleResize)
  resizeObserver.observe(el)
})

onUnmounted(() => {
  if (animationId) cancelAnimationFrame(animationId)
  if (resizeObserver) resizeObserver.disconnect()
  if (scene) {
    scene.traverse((obj) => {
      if (obj.geometry) obj.geometry.dispose()
      if (obj.material) {
        if (Array.isArray(obj.material)) obj.material.forEach((m) => m.dispose())
        else obj.material.dispose()
      }
    })
  }
  if (renderer) {
    renderer.dispose()
    if (renderer.domElement && renderer.domElement.parentNode) {
      renderer.domElement.parentNode.removeChild(renderer.domElement)
    }
  }
})
</script>

<style scoped>
.hologram-container {
  width: 100%;
  height: 100%;
}
.hologram-container :deep(canvas) {
  display: block;
}
</style>
