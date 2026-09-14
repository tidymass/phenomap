<template>
  <div ref="containerRef" class="globe-container"></div>
</template>

<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import * as THREE from 'three'

const containerRef = ref(null)
const CYAN = 0x22d3ee

let renderer, scene, camera, group, scanline, animationId, resizeObserver

// Evenly distributes `count` points on a sphere of the given radius
// (golden-angle / Fibonacci sphere -- no clustering at the poles).
function fibonacciSphere(count, radius) {
  const points = []
  const offset = 2 / count
  const increment = Math.PI * (3 - Math.sqrt(5))
  for (let i = 0; i < count; i++) {
    const y = i * offset - 1 + offset / 2
    const r = Math.sqrt(Math.max(0, 1 - y * y))
    const phi = i * increment
    const x = Math.cos(phi) * r
    const z = Math.sin(phi) * r
    points.push(new THREE.Vector3(x * radius, y * radius, z * radius))
  }
  return points
}

// Renders text to a 2D canvas and wraps it as a camera-facing sprite --
// simplest reliable way to get crisp, glowing text into a Three.js scene
// without needing an external font/typeface file.
function createTextSprite(text, { fontSize = 64, color = '#eafcff', glow = 'rgba(34,211,238,0.95)' } = {}) {
  const tracked = text.split('').join(' ') // hair-space letter tracking
  const canvas = document.createElement('canvas')
  const ctx = canvas.getContext('2d')
  const font = `700 ${fontSize}px -apple-system, "Helvetica Neue", Arial, sans-serif`
  ctx.font = font
  const padding = 28
  const textWidth = ctx.measureText(tracked).width
  canvas.width = Math.ceil(textWidth) + padding * 2
  canvas.height = fontSize + padding * 2
  // canvas resizing resets the 2D context, so font/align must be set again
  ctx.font = font
  ctx.textAlign = 'center'
  ctx.textBaseline = 'middle'
  ctx.shadowColor = glow
  ctx.shadowBlur = 22
  ctx.fillStyle = color
  ctx.fillText(tracked, canvas.width / 2, canvas.height / 2)
  ctx.shadowBlur = 10
  ctx.fillText(tracked, canvas.width / 2, canvas.height / 2)

  const texture = new THREE.CanvasTexture(canvas)
  texture.minFilter = THREE.LinearFilter
  texture.colorSpace = THREE.SRGBColorSpace
  const material = new THREE.SpriteMaterial({ map: texture, transparent: true, depthWrite: false })
  const sprite = new THREE.Sprite(material)
  const height = 0.5
  sprite.scale.set(height * (canvas.width / canvas.height), height, 1)
  return sprite
}

function buildGlobe(radius = 1.55, count = 150, neighborsPerNode = 2) {
  const g = new THREE.Group()
  const pts = fibonacciSphere(count, radius)

  // glowing node points
  const pointsGeo = new THREE.BufferGeometry().setFromPoints(pts)
  const pointsMat = new THREE.PointsMaterial({
    color: CYAN,
    size: 0.05,
    sizeAttenuation: true,
    transparent: true,
    opacity: 0.9,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  })
  g.add(new THREE.Points(pointsGeo, pointsMat))

  // connect each node to its nearest neighbors so the surface reads as a
  // network, not just scattered dots
  const lineVerts = []
  const seenEdges = new Set()
  for (let i = 0; i < pts.length; i++) {
    const dists = []
    for (let j = 0; j < pts.length; j++) {
      if (i === j) continue
      dists.push([pts[i].distanceToSquared(pts[j]), j])
    }
    dists.sort((a, b) => a[0] - b[0])
    for (let k = 0; k < neighborsPerNode; k++) {
      const j = dists[k][1]
      const key = i < j ? i + '-' + j : j + '-' + i
      if (seenEdges.has(key)) continue
      seenEdges.add(key)
      lineVerts.push(pts[i].x, pts[i].y, pts[i].z, pts[j].x, pts[j].y, pts[j].z)
    }
  }
  const lineGeo = new THREE.BufferGeometry()
  lineGeo.setAttribute('position', new THREE.Float32BufferAttribute(lineVerts, 3))
  const lineMat = new THREE.LineBasicMaterial({
    color: CYAN,
    transparent: true,
    opacity: 0.25,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  })
  g.add(new THREE.LineSegments(lineGeo, lineMat))

  // faint latitude/longitude shell so it still reads as a "globe"
  const shellGeo = new THREE.SphereGeometry(radius * 0.985, 16, 12)
  const shellMat = new THREE.MeshBasicMaterial({
    color: CYAN,
    wireframe: true,
    transparent: true,
    opacity: 0.06,
  })
  g.add(new THREE.Mesh(shellGeo, shellMat))

  // soft glowing core
  const coreGeo = new THREE.SphereGeometry(radius * 0.35, 24, 16)
  const coreMat = new THREE.MeshBasicMaterial({
    color: CYAN,
    transparent: true,
    opacity: 0.08,
    blending: THREE.AdditiveBlending,
    depthWrite: false,
  })
  g.add(new THREE.Mesh(coreGeo, coreMat))

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
  camera.position.set(0, 0, 7)
  camera.lookAt(0, 0, 0)

  renderer = new THREE.WebGLRenderer({ antialias: true, alpha: true })
  renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2))
  renderer.setSize(width, height)
  el.appendChild(renderer.domElement)

  const radius = 1.8
  group = buildGlobe(radius)
  scene.add(group)

  const scanMat = new THREE.MeshBasicMaterial({
    color: 0x8fe9f5,
    transparent: true,
    opacity: 0.3,
    blending: THREE.AdditiveBlending,
    side: THREE.DoubleSide,
    depthWrite: false,
  })
  scanline = new THREE.Mesh(new THREE.PlaneGeometry(4.2, 0.03), scanMat)
  scene.add(scanline)

  // wordmark sits at the exact center of the globe, static and always
  // legible -- not part of the rotating group, and drawn on top of the
  // network geometry so passing lines/points never cut through it
  const label = createTextSprite('PhenoMAP')
  label.position.set(0, 0, 0)
  label.material.depthTest = false
  label.renderOrder = 10
  scene.add(label)

  let t = 0
  function animate() {
    t += 0.012
    group.rotation.y += 0.0045
    group.rotation.x = Math.sin(t * 0.15) * 0.08
    scanline.position.y = Math.sin(t * 0.4) * (radius * 0.9)
    scanline.material.opacity = 0.2 + Math.random() * 0.14
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
.globe-container {
  width: 100%;
  height: 100%;
}
.globe-container :deep(canvas) {
  display: block;
}
</style>
