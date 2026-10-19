<template>
    <PhoneWrapper app-name="Minimap">
      <div class="minimap-container" ref="container">
        
        <div class="map-base">
          <svg class="minimap-layer terrain-layer"></svg>
          <svg class="minimap-layer roads-layer"></svg>
          <svg class="minimap-layer vehicle-layer"></svg>
        </div>
      </div>
    </PhoneWrapper>
  </template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import { useMinimapStore } from '../stores/minimapStore'
import PhoneWrapper from './PhoneWrapper.vue'

const store = useMinimapStore()
const container = ref(null)
const sharedLayers = [store.svgLayers.terrain, store.svgLayers.roads, store.svgLayers.vehicles]
const previousAspect = new Map()

onMounted(() => {
  store.init()
  
  // Attach layers to correct containers
  const terrainLayer = container.value.querySelector('.terrain-layer')
  const roadsLayer = container.value.querySelector('.roads-layer')
  const vehicleLayer = container.value.querySelector('.vehicle-layer')
  
  terrainLayer.appendChild(store.svgLayers.terrain)
  roadsLayer.appendChild(store.svgLayers.roads)
  vehicleLayer.appendChild(store.svgLayers.vehicles)

  // The shared layers use a square viewBox; the phone screen is portrait. Without "slice" the
  // map letterboxes and leaves flat grey bands above and below it.
  for (const layer of sharedLayers) {
    previousAspect.set(layer, layer.getAttribute('preserveAspectRatio'))
    layer.setAttribute('preserveAspectRatio', 'xMidYMid slice')
  }
})

onUnmounted(() => {
    for (const layer of sharedLayers) {
      const previous = previousAspect.get(layer)
      if (previous) layer.setAttribute('preserveAspectRatio', previous)
      else layer.removeAttribute('preserveAspectRatio')
    }
    previousAspect.clear()
    store.cleanup()
})
</script>

<style scoped>
.map-base {
  position: relative;
  flex: 1;
  min-height: 0;
  width: 100%;
  transform-origin: center center;
}

.minimap-container {
  display: flex;
  flex-direction: column;
  width: 100%;
  height: 100%;
  min-height: 0;
  overflow: hidden;
  background: rgba(40, 40, 40, 0.9);
}

.minimap-layer {
    position: absolute;
    inset: 0;
    width: 100%;
    height: 100%;
    pointer-events: none;
}
</style>