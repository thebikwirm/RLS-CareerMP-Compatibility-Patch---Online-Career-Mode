<template>
  <div
    ref="rootEl"
    class="popup-content rls-house choose-insurance"
    v-bng-scoped-nav="popupScopeBinding"
    v-bng-on-ui-nav:back="cancel"
  >
    <div class="popup-header">
      <span class="caption">
        {{ mode === "purchase" ? $translate.instant("ui.career.chooseInsurance.insureYour") : $translate.instant("ui.career.chooseInsurance.switchInsuranceForYour") }}
      </span>
      <h2 class="pop-title">{{ vehicleInfo.Name }}</h2>
    </div>
    <div class="content-wrapper scroll" v-bng-ui-nav-scroll>
      <BngOverflowContainer
        ref="overflowRef"
        class="insurance-shelf"
        :scroll-speed="10"
        :initial-index="selectedShelfIndex"
        use-bindings-only
        show-arrows
        no-wheel
      >
        <InsuranceCard
          v-for="(insurance, index) in insurancesData"
          :key="insurance.id"
          :insuranceData="insurance"
          :isSelected="selectedInsuranceId === insurance.id"
          :vehicleInfo="vehicleInfo"
          :isCurrentProvider="mode === 'change' && currentInsuranceId === insurance.id"
          class="insurance-card"
          @click="onShelfClick(insurance.id, index)"
        />
      </BngOverflowContainer>
    </div>
    <div class="buttons-wrapper">
      <div class="button-container">
        <!-- controller: LB/RB move the shelf, A on the (autofocused) primary picks, B cancels -->
        <HouseButton
          variant="quiet"
          binding="back"
          :bng-scoped-nav-autofocus="selectDisabled ? '' : null"
          @click="cancel">{{ $translate.instant("ui.common.cancel") }}</HouseButton>
        <span class="button-gap"></span>
        <HouseButton @click="viewCostBreakdown" :disabled="selectedShelfIndex === 0 || (mode === 'change' && selectedInsuranceId === currentInsuranceId)">{{ $translate.instant("ui.career.chooseInsurance.viewCostBreakdown") }}</HouseButton>
        <HouseButton
          class="select-button"
          variant="primary"
          binding="ok"
          :disabled="selectDisabled"
          :bng-scoped-nav-autofocus="selectDisabled ? null : ''"
          @click="continueWithInsurance">{{ buttonText }}</HouseButton>
      </div>
    </div>
  </div>
</template>

<script setup>
import { computed, onMounted, onUnmounted, ref, watch, useAttrs } from "vue"
import { BngOverflowContainer } from "@/common/components/base"
import { vBngOnUiNav, vBngScopedNav, vBngUiNavScroll } from "@/common/directives"
import useChooseInsurance from "../stores/chooseInsuranceComposable"
import { lua, useBridge } from "@/bridge"
import { InsuranceCard, PurchaseInsuranceDetails, ChangeInsuranceDetails } from "@/modules/career/components"
import { HouseButton } from "../components/house"
import { addPopup, closeLastPopups } from "@/services/popup"
import { useUINavBlocker } from "@/services/uiNavTracker"
import { DOM_UI_NAVIGATION_EVENT } from "@/services/uiNav"
import { $translate } from "@/services/translation"

const uiNavBlocker = useUINavBlocker()
uiNavBlocker.ensureNoBlock(["tab_l", "tab_r"])

//FIXME: This is a temporary solution to handle tab navigation. We need to find a better way to handle this.
const overflowRef = ref(null)
const rootEl = ref(null)
const onTabNav = (evt) => {
  if (evt.detail.value !== 1) return
  // the cost breakdown opens on top of this popup (a later .ins-pop in the popup host); LB / RB must
  // not move the shelf underneath it. Popups below this one (it opens from some) do not count.
  const root = rootEl.value
  if (root && [...document.querySelectorAll(".ins-pop")].some(el => root.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING)) return
  if (evt.detail.name === 'tab_l') overflowRef.value?.activatePrev()
  if (evt.detail.name === 'tab_r') overflowRef.value?.activateNext()
}

const props = defineProps({
  menuMode: {
    type: String,
    required: true
  },
  params: {
    type: Object,
    required: true
  },
  popupActive: Boolean
})

const emit = defineEmits(["return"])

const { units } = useBridge()

const attrs = useAttrs()
const scopeName = `_chooseInsuranceMain__${attrs.__id}`
const popupScopeBinding = computed(() => ({
  scopeId: scopeName,
  activated: props.popupActive,
  activateOnMount: props.popupActive,
  canDeactivate: () => false,
  preferAutoFocus: true,
  trapPolicy: "always",
}))

const selectedInsuranceId = ref(null)
const selectedShelfIndex = ref(0)

const {
  insurancesData,
  purchaseData,
  defaultInsuranceId,
  firstSelectedInsuranceId,
  vehicleInfo,
  requestDataForCurrentContext,
  mode,
  context,
  driverScoreData,
  currentInsuranceId,
} = useChooseInsurance()

onMounted(() => {
  window.addEventListener(DOM_UI_NAVIGATION_EVENT, onTabNav)
  mode.value = props.menuMode
  context.value = props.params

  // directly request insurance data without changing UI state
  if (props.menuMode === 'purchase' && props.params) {
    lua.career_modules_insurance_insurance.sendChooseInsuranceDataToTheUI(
      props.params.purchaseType,
      props.params.shopId,
      props.params.insuranceId
    )
  } else if (props.menuMode === 'change' && props.params) {
    lua.career_modules_insurance_insurance.sendChangeInsuranceDataToTheUI(props.params.vehicleId)
  }
})

// Sync shelf index with insurance selection
watch(selectedShelfIndex, (newIndex) => {
  if (insurancesData.value[newIndex]) {
    selectedInsuranceId.value = insurancesData.value[newIndex].id
  }
})

// set default selected insurance when data loads
watch(defaultInsuranceId, (defaultId) => {
  if (defaultId !== null) {
    selectedInsuranceId.value = defaultId

    const index = insurancesData.value.findIndex(ins => ins.id === defaultId)
    if (index !== -1) {
      selectedShelfIndex.value = index
    }
  }
}, { immediate: true })


const onShelfClick = (insuranceId, index) => {
  // when clicking on the centered insurance card, proceed with selection
  selectedInsuranceId.value = insuranceId
  selectedShelfIndex.value = index
}

const selectDisabled = computed(() => !selectedInsuranceId.value || (mode.value === "change" && selectedInsuranceId.value === currentInsuranceId.value))

const buttonText = computed(() => {
  if (mode.value === "change") {
    if (selectedInsuranceId.value === -1) {
      return $translate.instant("ui.career.chooseInsurance.removeCoverage")
    } else if (selectedInsuranceId.value === currentInsuranceId.value) {
      return $translate.instant("ui.career.chooseInsurance.currentProvider")
    } else {
      return $translate.instant("ui.career.chooseInsurance.moveVehicleHere")
    }
  }
  return $translate.instant("ui.career.chooseInsurance.selectThisOption")
})

const viewCostBreakdown = () => {
  if (mode.value === "purchase") {
    addPopup(PurchaseInsuranceDetails, { insuranceData: insurancesData.value[selectedShelfIndex.value], vehicleInfo: vehicleInfo.value, driverScoreData: driverScoreData.value })
  } else {
    addPopup(ChangeInsuranceDetails, {
      insuranceData: insurancesData.value[selectedShelfIndex.value],
      vehicleInfo: vehicleInfo.value,
      driverScoreData: driverScoreData.value,
    })
  }
}

const continueWithInsurance = () => {
  if (mode.value === "purchase") {
    if (selectedInsuranceId.value !== null && selectedInsuranceId.value !== undefined) {
      // update the insurance selection without reopening it since we are in a popup
      lua.career_modules_vehicleShopping.updateInsuranceSelection(selectedInsuranceId.value)
    }
    emit("return", true)
  } else if (mode.value === "change") {
    if (selectedInsuranceId.value && context.value?.vehicleId) {
      lua.career_modules_insurance_insurance.changeInvVehInsurance(context.value.vehicleId, selectedInsuranceId.value)
    }

    closeLastPopups(3)
  }
}

const cancel = () => {
  emit("return", true)
}

onUnmounted(() => {
  window.removeEventListener(DOM_UI_NAVIGATION_EVENT, onTabNav)
  // ensure shared context is cleared when popup is closed
  mode.value = null
  context.value = null
})

</script>

<style scoped lang="scss">
@import "../styles/rlsHouse.scss";

/* RLS house popup: near-black ground, the vehicle name as the title, a shelf of equal-height
   provider cards (selected = brighter panel), footer on the same ground with no divider and one
   orange action (select / move here). */
.choose-insurance {
  font-size: clamp(0.7rem, calc(1.48vh * var(--ui-scale, 1)), 2.4rem);
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  width: min(86em, 94vw);
  max-height: min(90vh, calc(100vh - 4rem));
  padding: 1.1em 1.1em 1em;
  border-radius: var(--radius-control);
  background: #1a1a1c;
  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.08), 0 18px 40px rgba(0, 0, 0, 0.55);
  color: #fff;
  overflow: hidden;
}

.popup-header {
  flex: 0 0 auto;
  display: grid;
  gap: 0.15em;
  min-width: 0;
}
.pop-title {
  margin: 0;
  font-size: 1.45em;
  font-weight: 800;
  line-height: 1.15;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.content-wrapper {
  flex: 1 1 auto;
  min-height: 0;
  width: 100%;
  display: flex;
  flex-direction: column;
  align-items: center;
  overflow-x: hidden;
  overflow-y: auto;
  /* the stable scrollbar gutter sits in the popup's right padding */
  margin-right: -0.55em;
  padding-right: 0.05em;
}

.insurance-shelf {
  --bng-overflow-container-background: transparent;
  --bng-overflow-container-fade-color: #1a1a1c;
  --bng-overflow-container-fade-color-hover: #2a2a2d;
  --binding-font-size: 1.5em;
  --bng-overflow-container-gap: 0.6em;
  --bng-icon-color: var(--muted);

  width: 100%;
  max-width: 100%;
  font-size: 1em;
  flex: 0 0 auto;

  :deep(.shelf-container) {
    overflow: visible;
  }
  :deep(.scroll-container) {
    align-items: stretch;
    padding: 0.4em 0.25em;
  }
}

.insurance-card {
  flex: 0 0 auto;
  width: 24em;
  min-height: 32em;
  z-index: unset !important;
}

.buttons-wrapper {
  flex: 0 0 auto;
}

.button-container {
  display: flex;
  align-items: center;
  gap: var(--space-2);
  .button-gap {
    flex: 1 1 auto;
  }
  > :deep(.house-button) {
    min-width: 7em;
  }
  > .select-button {
    min-width: 12em;
  }
}
</style>
