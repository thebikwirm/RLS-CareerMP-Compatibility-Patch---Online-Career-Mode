<template>
  <PhoneWrapper app-name="Job Broker" :expanded="s.expanded" :custom-back="back">
    <div class="broker" :class="{ expanded: s.expanded, 'market-home': s.view === 'markets', 'filters-screen': s.view === 'filters' }">
      <header class="apphead"><h2>{{ heading }}</h2><button class="icon-btn" :aria-label="s.expanded ? 'Collapse phone' : 'Expand phone'" @click="s.expanded = !s.expanded"><svg v-if="!s.expanded" viewBox="0 0 24 24"><path d="M4 9V4h5M15 4h5v5M20 15v5h-5M9 20H4v-5"/></svg><svg v-else viewBox="0 0 24 24"><path d="M9 4v5H4M15 4v5h5M20 15h-5v5M4 15h5v5"/></svg></button></header>
      <div v-if="s.data.employed" class="empty employed-state">
        <span class="empty-badge"><BngIcon :type="icons.badge" /></span>
        <p class="employed-copy">You have a job right now. You need to be unemployed to take independent work.</p>
        <button class="primary" @click="openEmployment">Open Employment</button>
      </div>
      <div v-else-if="!s.loaded" class="empty"><p>Loading available work…</p><button @click="s.refresh">Try again</button></div>
      <template v-else>
        <section v-if="s.view === 'markets'" class="market-body scroll">
          <p class="intro">Choose your market</p>
          <div class="market-grid"><button v-for="m in markets" :key="m.id" class="market-tile" :class="{ last: s.preferences.last === m.id }" @click="s.chooseMarket(m.id)">
            <span class="tile-img"><img :src="marketImage(m.id)" alt="" loading="lazy" /><BngIcon class="tile-glyph" :type="marketIcon(m.id)" /></span>
            <span class="tile-copy"><strong>{{ m.name }}</strong><span>{{ m.hint }}</span></span>
            <span class="pill" :class="s.data.offers.some(r => r.market === m.id) ? 'accent' : 'muted'">{{ loadCount(groupedOfferCount(s.data.offers.filter(r => r.market === m.id))) }}</span>
          </button></div>
          <button class="browse-all" @click="s.chooseMarket('all')">Browse all work <span class="pill">{{ loadCount(groupedOfferCount(s.data.offers)) }}</span></button>
        </section>
        <section v-else-if="s.view === 'filters'" class="filter-page scroll">
          <button class="text-btn" @click="s.view = 'loads'">‹ {{ marketName }}</button>
          <div v-if="s.market === 'all'" class="filter-group">
            <h3>Work type</h3>
            <div class="chips market-chips">
              <button v-for="m in markets" :key="m.id" type="button" :class="{ active: isMarketFilterActive(m.id) }" @click="toggleMarketFilter(m.id)">{{ m.name }}</button>
            </div>
            <p v-if="!s.filter.markets?.length" class="filter-note">All six markets included.</p>
          </div>
          <label>Max pickup distance<BngDropdown class="broker-dropdown" @open="syncDropdownFont" aria-label="Max pickup distance" :model-value="effectiveRadius" :items="radiusDropdownItems" @update:model-value="s.updateFilter('radius', $event)" /></label>
          <label>Pickup location<BngDropdown class="broker-dropdown" @open="syncDropdownFont" aria-label="Pickup location" :model-value="s.filter.pickupFac || ''" :items="pickupLocationOptions" @update:model-value="s.updateFilter('pickupFac', $event)" /></label>
          <label>Delivery location<BngDropdown class="broker-dropdown" @open="syncDropdownFont" aria-label="Delivery location" :model-value="s.filter.destFac || ''" :items="destLocationOptions" @update:model-value="s.updateFilter('destFac', $event)" /></label>
          <label v-if="s.market === 'specialty' || s.market === 'all'">Specialty cargo<BngDropdown class="broker-dropdown" @open="syncDropdownFont" aria-label="Specialty cargo type" :model-value="s.filter.subtype" :items="cargoOptions" @update:model-value="s.updateFilter('subtype', $event)" /></label>
          <div v-if="trailerTypes.length" class="filter-group"><h3>Trailer type</h3><div class="chips"><button v-for="type in trailerTypes" :key="type" type="button" :class="{ active: s.filter.trailers.includes(type) }" @click="toggleTrailer(type)">{{ type }}</button></div></div>
          <label v-if="s.market === 'all' || s.market === 'trailers'">Trailer arrangement<BngDropdown class="broker-dropdown" @open="syncDropdownFont" aria-label="Trailer arrangement" :model-value="s.filter.arrangement" :items="arrangementOptions" @update:model-value="s.updateFilter('arrangement', $event)" /></label>
          <div class="filter-actions"><button @click="s.resetFilters">Reset filters</button><button class="primary" @click="s.view = 'loads'">Show {{ groupedOfferCount(s.rows) }} loads</button></div>
        </section>
        <template v-else-if="s.view === 'loads' || s.view === 'jobs'">
          <div v-if="s.view === 'loads' && (!s.selected || s.expanded)" class="toolbar">
            <div class="breadcrumb"><button class="text-btn" @click="s.view = 'markets'">‹ Markets</button><button v-if="s.scope" class="text-btn" @click="s.scope = ''">All pickups</button></div>
            <input :value="s.filter.search" v-bng-text-input placeholder="Search loads or destinations" aria-label="Search loads" @input="s.updateFilter('search', $event.target.value)" @keydown.stop @keyup.stop />
            <div class="toolbar-row"><BngDropdown class="broker-dropdown" @open="syncDropdownFont" :model-value="s.filter.sort" :items="sortOptions" aria-label="Sort loads" @update:model-value="s.updateFilter('sort', $event)" /><button @click="s.view = 'filters'">Filters<span v-if="filterCount" class="pill accent count">{{ filterCount }}</span></button><button v-if="filterCount" class="text-btn" @click="s.resetFilters">Reset</button><button class="icon-btn" aria-label="Refresh loads" @click="s.refresh"><BngIcon :type="icons.restart" /></button></div>
          </div>
          <div v-if="s.view === 'jobs' && (!s.selected || s.expanded)" class="jobs-tabs"><button :class="{ active: jobsTab === 'loads' }" @click="jobsTab = 'loads'">Loads<span class="pill count">{{ activeJobs.length }}</span></button><button :class="{ active: jobsTab === 'route' }" @click="jobsTab = 'route'; s.selected = null">Route plan</button></div>
          <div v-if="s.view === 'jobs' && jobsTab === 'route' && !s.selected" class="scroll route-plan">
            <RouteMap v-if="s.data.stops.length" class="plan-map" :legs="planPreview?.legs || []" :points="planPreview?.points || {}">{{ planLoading ? 'Tracing route…' : 'Route preview unavailable' }}</RouteMap>
            <div class="route-summary">
              <div class="route-stats">
                <div class="stat"><span class="stat-key">Stops</span><span class="stat-value">{{ s.data.stops.length }}</span></div>
                <div class="stat"><span class="stat-key">Total drive</span><span class="stat-value">{{ s.data.route?.total ? dist(s.data.route.total) : '—' }}</span></div>
                <div class="stat"><span class="stat-key">Reserved</span><span class="stat-value">{{ s.data.reservationCount }}</span></div>
              </div>
              <div class="route-actions">
                <button class="primary" :disabled="working || !s.data.stops.length" @click="s.action('showRoute')"><BngIcon :type="icons.routeSimple" />Show on map</button>
                <button :disabled="working || s.data.stops.length < 2" @click="s.action('optimizeStops')">Auto-order</button>
                <button class="text-btn" :disabled="working" @click="s.action('clearRoute')">Clear markers</button>
              </div>
            </div>
            <div v-if="s.data.stops.length" class="stop-list">
              <div v-for="(stop, index) in s.data.stops" :key="stop.id" class="plan-stop" :class="stop.kind">
                <span class="plan-index">{{ index + 1 }}</span>
                <button class="stop-main" @click="openStop(stop)">
                  <span class="stop-kind pill" :class="stop.kind === 'pickup' ? 'accent' : ''">{{ stop.kind === 'pickup' ? 'Pickup' : 'Deliver' }}</span>
                  <strong>{{ stopJob(stop)?.title || 'Unavailable load' }}</strong>
                  <small>{{ stop.name || stopJob(stop)?.[stop.kind === 'pickup' ? 'from' : 'to'] }}</small>
                </button>
                <span class="leg"><span class="leg-dist">{{ legDistance(stop) }}</span><span class="leg-status">{{ stopJob(stop)?.status ? statusName(stopJob(stop).status) : 'Saved' }}</span></span>
                <div class="plan-move"><button :disabled="working || !index" aria-label="Move stop up" @click="s.action('moveStop', { index: index + 1, delta: -1 })"><BngIcon :type="icons.arrowSmallUp" /></button><button :disabled="working || index === s.data.stops.length - 1" aria-label="Move stop down" @click="s.action('moveStop', { index: index + 1, delta: 1 })"><BngIcon :type="icons.arrowSmallDown" /></button></div>
              </div>
            </div>
            <div v-else class="empty"><BngIcon :type="icons.routeSimple" /><h3>No stops yet</h3><p>Save loads to plan a route. Saving does not reserve them.</p></div>
          </div>
          <div v-else class="workarea" :class="{ 'has-detail': !!s.selectedRow }">
            <div v-show="!s.selectedRow || s.expanded" ref="listEl" class="scroll load-list" @scroll="rememberScroll">
              <p class="list-caption">{{ visibleRows.length }} loads <span v-if="s.view === 'jobs'">{{ s.data.reservationCount }} reserved</span></p>
              <div class="list-columns" role="row">
                <div
                  v-for="col in tableColumns"
                  :key="col.key"
                  class="col-head"
                  :class="{ 'span-2': col.span === 2, start: col.start }"
                  role="columnheader"
                >
                  <span class="col-label" :title="col.hint || col.label">{{ col.label }}</span>
                  <span class="col-chevs" aria-hidden="true">
                    <button type="button" class="chev-btn" :class="{ active: columnSortActive(col.key, 'asc') }" :aria-label="col.ascLabel" @click.stop="setColumnSort(col.key, 'asc')"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 14l5-5 5 5" /></svg></button>
                    <button type="button" class="chev-btn" :class="{ active: columnSortActive(col.key, 'desc') }" :aria-label="col.descLabel" @click.stop="setColumnSort(col.key, 'desc')"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M7 10l5 5 5-5" /></svg></button>
                  </span>
                </div>
              </div>
              <button v-for="row in renderedRows" :key="row.id" class="load-row" :class="{ selected: s.selected === row.id }" :aria-pressed="s.selected === row.id" @click="select(row)">
                <span class="row-thumb" :class="{ empty: !row.originPreview }"><img v-if="row.originPreview" :src="row.originPreview" alt="" loading="lazy" /><BngIcon v-else :type="marketIcon(row.market)" /></span>
                <div class="row-summary">
                  <div class="card-top"><h3 :title="row.title"><span v-if="row.groupCount > 1" class="group-mult">{{ row.groupCount }}×</span>{{ row.title }}</h3><strong class="pay compact-pay">{{ money(payOf(row)) }}</strong></div>
                  <div class="route" :title="row.from + ' → ' + row.to">{{ row.from }} → {{ row.to }}</div>
                  <div class="row-bottom"><span class="row-meta"><span :title="dist(row.pickupDistance) + ' to pickup'"><BngIcon :type="icons.mapPoint" />{{ dist(row.pickupDistance) }}</span><span :title="dist(row.haulDistance) + ' haul'"><BngIcon :type="icons.routeSimple" />{{ dist(row.haulDistance) }}</span></span><span>{{ fact(row) }}</span></div>
                  <span v-if="row.status || row.unlocked === false" class="pill status" :class="row.status === 'active' ? 'accent' : ''">{{ row.status ? statusName(row.status) : row.lockedReason || 'Logistics level required' }}</span>
                </div>
                <span class="wide-cell" :aria-label="dist(row.pickupDistance) + ' to pickup'">{{ dist(row.pickupDistance) }}</span>
                <span class="wide-cell" :aria-label="dist(row.haulDistance) + ' haul'">{{ dist(row.haulDistance) }}</span>
                <span class="wide-cell cargo-cell" :title="fact(row)">{{ fact(row) }}</span>
                <strong class="wide-cell pay">{{ money(payOf(row)) }}</strong>
              </button>
              <button v-if="renderedRows.length < visibleRows.length" class="browse-all" @click="rowLimit += 100">Show more loads</button><div v-if="!visibleRows.length" class="empty"><p>{{ s.view === 'jobs' ? 'No active loads.' : 'No loads match these filters.' }}</p><button v-if="s.view === 'loads'" @click="s.resetFilters">Reset filters</button></div>
            </div>
            <section v-if="s.selectedRow" class="detail-pane" aria-label="Selected load"><div class="scroll detail-scroll">
              <div class="detail-hero" :class="{ 'no-photo': !s.selectedRow.originPreview }">
                <img v-if="s.selectedRow.originPreview" :src="s.selectedRow.originPreview" alt="" />
                <button class="icon-btn detail-close" :aria-label="s.expanded ? 'Clear selection' : 'Back to loads'" :title="s.expanded ? 'Clear selection' : 'Back to loads'" @click="closeDetail"><svg viewBox="0 0 24 24"><path d="M6 6l12 12M18 6L6 18"/></svg></button>
                <div class="detail-hero-copy">
                  <p class="eyebrow">{{ markets.find(m => m.id === s.selectedRow.market)?.name }}</p>
                  <h2><span v-if="selectedListRow?.groupCount > 1" class="group-mult">{{ selectedListRow.groupCount }}×</span>{{ s.selectedRow.title }}</h2>
                </div>
                <div class="detail-hero-pay">
                  <span class="detail-pay">{{ money(payOf(s.selectedRow)) }}</span>
                  <span v-if="s.selectedRow.status" class="pill accent">{{ statusName(s.selectedRow.status) }}</span>
                  <span v-else-if="s.selectedRow.kind === 'material'" class="pill">Full contract</span>
                </div>
              </div>
              <div v-if="showLoader" class="loader">
                <div class="block-head"><div class="kicker">Load at {{ s.selectedRow.from }}</div><button type="button" class="tip-btn" :class="{ spinning: containerLoading }" :disabled="containerLoading" aria-label="Refresh equipment" data-tip="Rescan cargo space" @click="refreshContainers"><svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.35-5.65"/><path d="M20 4v4.5h-4.5"/></svg></button><button v-if="parcelBoxes.length > 1 && pickupParcels.length > 1" type="button" class="text-btn split-btn" :disabled="working" @click="autoSplit()">Auto split</button></div>
                <p v-if="containerLoading || containerError || !parcelBoxes.length" class="muted" role="status" aria-live="polite">{{ containerLoading ? 'Checking nearby cargo space…' : containerError || 'No cargo boxes nearby. Bring a vehicle with cargo space, then refresh.' }}</p>
                <template v-else>
                  <p v-if="loadVehicle" class="load-veh">Into your {{ loadVehicle }}</p>
                  <ul class="bins" aria-label="Cargo boxes">
                    <li v-for="(c, i) in parcelBoxes" :key="c.key" class="bin" :class="{ planned: boxUse(c.key) > 0 }">
                      <span class="bin-no">{{ i + 1 }}</span>
                      <span class="bin-copy"><strong>{{ boxLabel(c) }}</strong><small v-if="!loadVehicle">{{ c.vehName || '' }}</small></span>
                      <span class="bin-left"><b>{{ boxLeft(c) }}</b> left</span>
                      <span class="bin-bar" :title="`${boxHeld(c)} held · ${boxUse(c.key)} planned · ${boxLeft(c)} free of ${boxCap(c)}`"><span class="held" :style="{ flexBasis: share(boxHeld(c), boxCap(c)) }"></span><span class="plan" :style="{ flexBasis: share(boxUse(c.key), boxCap(c)) }"></span></span>
                    </li>
                  </ul>
                  <div class="parcels" role="group" aria-label="Parcels to load">
                    <div v-for="g in pickupGroups" :key="g.id" class="parcel" :class="{ off: !groupLoad(g), stuck: groupStuck(g) > 0 }">
                      <button type="button" class="tick" role="checkbox" :aria-checked="!groupLoad(g) ? 'false' : groupLoad(g) === g.groupCount ? 'true' : 'mixed'" :class="{ part: groupLoad(g) && groupLoad(g) < g.groupCount }" :aria-label="`Load ${g.title}`" @click="toggleGroup(g)"><svg viewBox="0 0 24 24"><path v-if="groupLoad(g) && groupLoad(g) < g.groupCount" d="M6 12h12" /><path v-else d="M5 12.5l4.2 4.2L19 7" /></svg></button>
                      <span class="parcel-copy"><strong><span v-if="g.groupCount > 1" class="group-mult">{{ g.groupCount }}×</span>{{ g.title }}</strong><small><span v-if="g.status && !s.selectedRow.status">Reserved</span><span>{{ `${slotsOf(g)} ${slotsOf(g) === 1 ? 'slot' : 'slots'}${g.groupCount > 1 ? ' each' : ''}` }}</span><span>{{ g.to }}</span></small></span>
                      <span v-if="g.groupCount > 1 && groupLoad(g)" class="count" role="group" :aria-label="`How many ${g.title} to load`"><button type="button" aria-label="Load one fewer" @click="stepGroup(g, -1)">−</button><b>{{ groupLoad(g) }}</b><button type="button" aria-label="Load one more" :disabled="groupLoad(g) >= g.groupCount" @click="stepGroup(g, 1)">+</button></span>
                      <span v-if="groupLoad(g)" class="splits">
                        <button v-for="sp in groupSplits(g)" :key="sp.key" type="button" class="box-pick" :disabled="!canMove(sp.job)" :title="canMove(sp.job) ? 'Move one to the next box with room' : 'No other box has room'" @click="cycleBox(sp.job)"><span class="bin-no">{{ boxIndex(sp.key) + 1 }}</span>{{ boxLabel(boxByKey(sp.key)) }}<em v-if="g.groupCount > 1">×{{ sp.n }}</em><svg v-if="canMove(sp.job)" viewBox="0 0 24 24"><path d="M7 4v16M7 20l-3-3M7 20l3-3M17 20V4M17 4l-3 3M17 4l3 3" /></svg></button>
                        <span v-if="groupStuck(g)" class="box-pick nope">{{ groupStuck(g) > 1 || g.groupCount > 1 ? `${groupStuck(g)} won't fit` : 'No room' }}</span>
                      </span>
                    </div>
                  </div>
                </template>
              </div>
              <div class="detail-head">
                <div class="facts">
                  <div v-for="f in detailFacts" :key="f.k" class="fact"><span class="fact-key">{{ f.k }}</span><span class="fact-value" :class="f.cls"><BngIcon v-if="f.icon" :type="f.icon" />{{ f.v }}</span></div>
                </div>
              <p v-if="s.selectedRow.kind !== 'material'" class="pay-note">{{ s.selectedRow.kind === 'cars' || Number(s.selectedRow.levelBonus) > 0 ? 'Pay shown includes your Logistics level bonus.' : 'Pay shown is the base rate.' }} On-time, no-damage and parking bonuses are paid on top.</p>
                <p v-if="s.selectedRow.unlocked === false" class="note warn">{{ s.selectedRow.lockedReason || 'Locked at your Logistics level.' }}</p>
              </div>
              <div class="route-row" aria-label="Route">
                <div class="route-cell"><small>Pickup</small><strong>{{ s.selectedRow.from }}</strong><span class="hint">{{ dist(s.selectedRow.pickupDistance) }} away</span></div>
                <span class="route-arrow"><svg viewBox="0 0 24 24" aria-hidden="true"><path d="M9 5l7 7-7 7" /></svg><em>{{ dist(s.selectedRow.haulDistance) }}</em></span>
                <div class="route-cell"><small>Delivery</small><strong>{{ s.selectedRow.to }}</strong><span class="hint">{{ dist(s.selectedRow.haulDistance) }} haul</span></div>
              </div>
              <div v-if="s.selectedRow.remaining != null" class="progress" aria-label="Progress">
                <div class="bar"><span class="done" :style="{ width: pct(s.selectedRow.delivered) }"></span><span class="transit" :style="{ width: pct(s.selectedRow.inTransit) }"></span></div>
                <div class="legend"><span><b>{{ s.selectedRow.delivered || 0 }}</b> delivered</span><span><b>{{ s.selectedRow.inTransit || 0 }}</b> in transit</span><span><b>{{ s.selectedRow.remaining }}</b> remaining</span></div>
              </div>
              <div v-if="s.selectedRow.atPickup && s.selectedRow.kind === 'material'" class="pickup-form">
                <div class="block-head"><div class="kicker">Load into</div><button type="button" class="tip-btn" :class="{ spinning: containerLoading }" :disabled="containerLoading" aria-label="Refresh equipment" data-tip="Rescan cargo space" @click="refreshContainers"><svg viewBox="0 0 24 24"><path d="M20 12a8 8 0 1 1-2.35-5.65"/><path d="M20 4v4.5h-4.5"/></svg></button></div>
                <p v-if="containerLoading || containerError || !s.containers.length" class="muted" role="status" aria-live="polite">{{ containerLoading ? 'Checking nearby cargo space…' : containerError || 'No cargo containers detected. Bring a vehicle with cargo boxes or a suitable tank, then refresh.' }}</p>
                <div v-else class="chips" role="radiogroup" aria-label="Cargo space"><button v-for="c in s.containers" :key="c.key" type="button" role="radio" :aria-checked="container === c.key" :class="{ active: container === c.key }" @click="container = c.key">{{ c.name }} <span class="pill">{{ c.free }} free</span></button></div>
                <label v-if="s.selectedRow.kind === 'material'">Quantity ({{ s.selectedRow.unit }})<input v-model.number="amount" type="number" min="0.001" step="any" aria-label="Quantity" v-bng-text-input @keydown.stop @keyup.stop /></label>
              </div>
              <div v-if="s.selectedRow.kind === 'cars' && s.selectedRow.status" class="car-choices">
                <div class="kicker">Vehicles</div>
                <button v-for="car in s.selectedRow.vehicles" :key="car.key" type="button" class="car" :class="{ picked: selectedCars.includes(car.key), done: car.status && car.status !== 'pending' }" :disabled="!!(car.status && car.status !== 'pending')" :aria-pressed="selectedCars.includes(car.key)" @click="toggleCar(car.key)"><span class="car-img"><img v-if="car.thumbnail" :src="car.thumbnail" alt="" loading="lazy" /><BngIcon v-else :type="icons.keys1" /></span><span class="car-copy"><strong>{{ car.label }}</strong><small>{{ car.destFacName }}</small></span><span class="car-state" :class="car.status === 'delivered' ? 'ok' : car.status && car.status !== 'pending' ? 'busy' : ''">{{ car.status === 'delivered' ? 'Delivered' : car.status && car.status !== 'pending' ? car.status : 'Pending' }}</span></button>
              </div>
              <button class="text-btn" @click="s.view = 'loaners'; s.selected = null">Browse loaner equipment →</button>
              <RouteMap v-if="!s.expanded && !showLoader" class="detail-map inline" :legs="routePreview?.legs || []" :points="routePreview?.points || {}">{{ routeLoading ? 'Tracing route…' : 'Route preview unavailable' }}</RouteMap>
            </div><div v-if="s.expanded && !showLoader" class="detail-map-slot"><RouteMap class="detail-map" :legs="routePreview?.legs || []" :points="routePreview?.points || {}">{{ routeLoading ? 'Tracing route…' : 'Route preview unavailable' }}</RouteMap></div><div class="detail-actions">
              <template v-if="!s.selectedRow.status && showLoader"><div class="next-step"><span class="kicker">Here</span><span class="next-step-text">{{ loadStep.hint }}</span></div><button class="primary" :disabled="working || loadStep.disabled" @click="loadParcels">{{ loadStep.label }}</button><button :disabled="working || s.selectedRow.unlocked === false" @click="reserveSelected">{{ reserveAmount > 1 ? `Reserve ${reserveAmount} instead` : 'Reserve instead' }}</button><button @click="s.action('plan', { id: s.selectedRow.id })">{{ isSaved(s.selectedRow) ? 'Remove saved plan' : 'Save to route' }}</button></template>
              <template v-else-if="!s.selectedRow.status"><div v-if="reserveGroup > 1" class="reserve-amount"><span class="kicker">Reserve</span><span class="count" role="group" aria-label="How many to reserve"><button type="button" aria-label="Reserve one fewer" :disabled="reserveAmount <= 1" @click="stepReserve(-1)">−</button><b>{{ reserveAmount }}</b><button type="button" aria-label="Reserve one more" :disabled="reserveAmount >= reserveMax" @click="stepReserve(1)">+</button></span><span class="reserve-note"><span>of {{ reserveGroup }}</span><i aria-hidden="true"></i><span>{{ reserveSlots(reserveAmount) }}</span></span><span class="reserve-pay">{{ money(payOf(s.selectedRow) * reserveAmount) }}</span></div><button class="primary" :disabled="working || s.selectedRow.unlocked === false" @click="reserveSelected">{{ reserveAmount > 1 ? `Reserve ${reserveAmount} loads` : 'Reserve load' }}</button><button @click="s.action('plan', { id: s.selectedRow.id })">{{ isSaved(s.selectedRow) ? 'Remove saved plan' : 'Save to route' }}</button></template>
              <template v-else-if="s.selectedRow.status !== 'complete' && nextStep">
                <div class="next-step"><span class="kicker">Next</span><span class="next-step-text">{{ nextStep.hint }}</span></div>
                <button class="primary" :disabled="working || nextStep.disabled" @click="nextStep.run()">{{ nextStep.label }}</button>
                <button v-if="nextStep.key !== 'toPickup'" :disabled="working" @click="s.action('navigate', { id: s.selectedRow.id, leg: 'pickup' })">Navigate to pickup</button>
                <button v-if="s.selectedRow.atPickup && s.selectedRow.kind !== 'parcel' && !['stage', 'collect', 'load'].includes(nextStep.key)" :disabled="working || ['parcel','material'].includes(s.selectedRow.kind) && (!container || s.selectedRow.kind === 'material' && !validAmount)" @click="collect">{{ s.selectedRow.kind === 'cars' ? 'Stage selected vehicles' : 'Collect load' }}</button>
                <button v-if="!['toDelivery', 'deliver'].includes(nextStep.key)" :disabled="working" @click="s.action('navigate', { id: s.selectedRow.id, leg: 'delivery' })">Navigate to delivery</button>
                <button v-if="s.selectedRow.status === 'reserved'" :disabled="working" @click="cancelReservation">{{ groupJobIds.length > 1 ? `Cancel ${groupJobIds.length} reservations` : 'Cancel reservation' }}</button>
                <button @click="s.action('plan', { id: s.selectedRow.id })">{{ s.data.plans[s.selectedRow.id] ? 'Remove from route' : 'Add to route' }}</button>
                <button v-if="s.selectedRow.status === 'active'" :disabled="working" @click="abandon">{{ confirmingAbandon ? `Confirm abandon${groupJobIds.length > 1 ? ' ' + groupJobIds.length : ''}, ${money(groupFine)}` : groupJobIds.length > 1 ? `Abandon all ${groupJobIds.length}` : 'Abandon work' }}</button><small v-if="confirmingAbandon">Existing delivery fines and reputation rules apply.</small>
              </template>
            </div></section>
            <aside v-else class="detail-placeholder" aria-label="Load details"><BngIcon :type="icons.cardboardBox" /><h3>Select a load</h3><p>Review the route, cargo and requirements here.</p><small>{{ s.view === 'jobs' ? 'Manage your pickup and delivery.' : 'Reserve a load or save it to your route.' }}</small></aside>
          </div>
        </template>
        <section v-else-if="s.view === 'loaners'" class="scroll loaners">
          <div class="depot-strip"><strong>{{ s.data.depot?.name || 'No depot available' }}</strong><button class="text-btn" :disabled="!s.data.depot" @click="s.action('navigateDepot')">Navigate to depot →</button></div>
          <template v-if="s.data.rentals.length"><h3>Your equipment</h3><div class="loaner-list"><article v-for="r in s.data.rentals" :key="r.id" class="loaner-card"><div v-if="r.preview" class="loaner-img"><img :src="r.preview" alt="" loading="lazy" /></div><div class="card-top"><strong>{{ r.name }}</strong><span>{{ rate(r.rate) }}/hr</span></div><p class="pills"><span class="pill" :class="r.status === 'reserved' ? 'accent' : 'ok'">{{ r.status === 'reserved' ? 'Reserved' : 'Rented' }}</span><span class="pill soft">{{ r.status === 'reserved' ? 'Rate locked' : 'Billed while out' }}</span><span v-if="r.status === 'rented' && r.vehicleSpawned === false" class="pill soft">Stored off map</span></p><div class="rental-actions"><button v-if="r.status === 'reserved'" class="primary" :disabled="working || !s.data.depot?.atDepot" @click="s.action('collectRental', { id: r.id })">Collect</button><button v-if="r.status === 'reserved'" :disabled="working" @click="s.action('cancelRental', { id: r.id })">Cancel</button><button v-if="r.status === 'rented'" :disabled="working" @click="s.action('navigateRental', { id: r.id })">Locate vehicle</button><button v-if="r.status === 'rented'" :disabled="working || !s.data.depot?.atDepot" @click="s.action('returnRental', { id: r.id })">Return empty</button></div></article></div></template>
          <h3>Available equipment</h3><div class="loaner-list"><article v-for="r in s.data.loaners" :key="r.id" class="loaner-card"><div v-if="r.preview" class="loaner-img"><img :src="r.preview" alt="" loading="lazy" /></div><div class="card-top"><strong>{{ r.name }}</strong><span class="pay">{{ rate(r.rate) }}/hr</span></div><p class="pills"><span class="pill">{{ markets.find(m => m.id === r.market)?.name }}</span><span class="pill soft">{{ r.basic ? 'Standard fleet' : 'Visiting stock' }}</span><span v-if="capacityText(r)" class="pill soft">{{ capacityText(r) }}</span></p><div class="rental-actions"><button class="primary" :disabled="working || !s.data.depot" @click="s.action('reserveRental', { id: r.id })">Reserve</button><button @click="s.chooseMarket(r.market)">Explore work</button></div></article></div>
          <p class="muted">Rates are per hour of unpaused simulation time, not the dashboard clock. Quotes lock when booked. Billing runs from collection to return, including parked time.</p>
        </section>
        <nav class="nav"><button :class="{ active: ['markets','loads','filters'].includes(s.view) }" @click="s.view = 'markets'; s.selected = null"><BngIcon :type="icons.search" /><span>Loads</span></button><button :class="{ active: s.view === 'jobs' }" @click="s.view = 'jobs'; s.selected = null"><BngIcon :type="icons.listIndented" /><span>My Loads</span></button><button :class="{ active: s.view === 'loaners' }" @click="s.view = 'loaners'; s.selected = null"><BngIcon :type="icons.carCoins" /><span>Loaners</span></button></nav>
      </template>
      <button v-if="s.message" class="message" aria-live="polite" @click="s.message = ''">{{ s.message }} <span>×</span></button>
    </div>
  </PhoneWrapper>
</template>

<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import { openPhoneRoute } from '../utils/phoneNavigation'
import { useEvents } from '@/services/events'
import { vBngTextInput } from '@/common/directives'
import { BngDropdown, BngIcon, icons } from '@/common/components/base'
import { useBridge } from '@/bridge'
import PhoneWrapper from './PhoneWrapper.vue'
import RouteMap from '../components/RouteMap.vue'
import { brokerLocationOptions, brokerRadiusOptions, groupBrokerRows, groupedOfferCount, markets, usePhoneBrokerStore } from '../stores/phoneBrokerStore'
import { callModLua } from '../utils/installLuaBridgeFallbacks'
const s = usePhoneBrokerStore(), route = useRoute(), router = useRouter(), events = useEvents(), { units } = useBridge()
const openEmployment = () => openPhoneRoute(router, 'phone-employment')
const listEl = ref(null), jobsTab = ref('loads'), container = ref(''), amount = ref(1), selectedCars = ref([]), confirmingAbandon = ref(false)
const rowLimit = ref(100)
const routePreview = ref(null), routeLoading = ref(false), planPreview = ref(null), planLoading = ref(false)
let previewRequest = 0
async function loadRoutePreview() {
  const id = s.selectedRow?.id
  routePreview.value = null
  if (!id) return
  const request = ++previewRequest
  routeLoading.value = true
  try { const r = await callModLua('ui_phone_logistics.requestRoutePreview', id); if (request === previewRequest) routePreview.value = r && r.legs ? r : null }
  catch { if (request === previewRequest) routePreview.value = null }
  finally { if (request === previewRequest) routeLoading.value = false }
}
async function loadPlanPreview() {
  planLoading.value = true
  try { const r = await callModLua('ui_phone_logistics.requestPlanPreview'); planPreview.value = r && r.legs ? r : null }
  catch { planPreview.value = null }
  finally { planLoading.value = false }
}
watch(() => s.selectedRow?.id, loadRoutePreview)
watch(() => [s.view, jobsTab.value, s.data.stops.map(x => x.id).join(',')], ([view, tab]) => { if (view === 'jobs' && tab === 'route') loadPlanPreview() }, { immediate: true })
const validAmount = computed(() => Number.isFinite(Number(amount.value)) && Number(amount.value) > 0)
const renderedRows = computed(() => visibleRows.value.slice(0, rowLimit.value))
watch(() => [s.market, s.filter, s.view], () => { rowLimit.value = 100 })
let refreshTimer, containerTimer
const containerLoading = ref(false), containerError = ref('')
let containerRequest = 0
const cargoOptions = [{ value: '', label: 'All cargo' }, { value: 'cement', label: 'Concrete' }, { value: 'cash', label: 'Cash' }]
const arrangementOptions = [{ value: '', label: 'Any' }, { value: 'supplied', label: 'Trailer supplied' }, { value: 'own', label: 'Bring your own' }]
const sortOptions = [
  { value: 'near', label: 'Nearest pickup' },
  { value: 'pay', label: 'Highest payout' },
  { value: 'short', label: 'Shortest haul' },
  { value: 'long', label: 'Longest haul' },
  { value: 'rate', label: 'Best pay per distance' },
  { value: 'titleAz', label: 'Load name A → Z' },
  { value: 'pickupAz', label: 'Pickup location A → Z' },
  { value: 'pickupZa', label: 'Pickup location Z → A' },
  { value: 'destAz', label: 'Delivery location A → Z' },
  { value: 'destZa', label: 'Delivery location Z → A' },
]
const containerOptions = computed(() => [{ value: '', label: 'Choose cargo space' }, ...s.containers.map(c => ({ value: c.key, label: `${c.name} (${c.free} free)` }))])
const working = computed(() => s.pending || s.data.busy)
const marketName = computed(() => markets.find(m => m.id === s.market)?.name || 'All work')
const heading = computed(() => s.view === 'markets' ? 'Find work' : s.view === 'jobs' ? 'My Loads' : s.view === 'loaners' ? 'Loaners' : s.view === 'filters' ? 'Filters' : marketName.value)
const activeJobs = computed(() => s.data.jobs.filter(j => !['complete', 'cancelled'].includes(j.status)))
const visibleRows = computed(() => groupBrokerRows(
  s.view === 'jobs' ? activeJobs.value : s.rows,
  { byStatus: s.view === 'jobs' },
))
const selectedListRow = computed(() => {
  if (!s.selected) return null
  return visibleRows.value.find(r => r.id === s.selected || r.groupOfferIds?.includes(s.selected)) || null
})
const filterCount = computed(() => Number(!!s.filter.radius)
  + Number(!!s.filter.subtype)
  + Number(!!s.filter.arrangement)
  + Number(!!s.filter.trailers.length)
  + Number(!!s.filter.pickupFac)
  + Number(!!s.filter.destFac)
  + Number(s.market === 'all' && !!s.filter.markets?.length))
const trailerTypes = computed(() => [...new Set(s.data.offers.filter(r => (s.market === 'all' || r.market === s.market) && r.trailerType).map(r => r.trailerType))].sort())
const pickupLocationOptions = computed(() => brokerLocationOptions(s.data.offers || [], s.market, 'pickup'))
const destLocationOptions = computed(() => brokerLocationOptions(s.data.offers || [], s.market, 'delivery'))
const radiusPresets = computed(() => brokerRadiusOptions(s.data.offers || [], s.market))
const effectiveRadius = computed(() => {
  const r = s.filter.radius
  if (!r) return 0
  const presets = radiusPresets.value.map(p => p.value)
  if (presets.includes(r)) return r
  const next = presets.find(v => v >= r)
  return next ?? presets[presets.length - 1] ?? 0
})
const radiusDropdownItems = computed(() => {
  const items = [{ value: 0, label: 'Any distance' }]
  for (const preset of radiusPresets.value) {
    items.push({ value: preset.value, label: `Within ${dist(preset.value)}` })
  }
  const r = s.filter.radius
  if (r && !items.some(i => i.value === r)) {
    items.push({ value: r, label: `Within ${dist(r)} (saved)` })
  }
  return items
})
// Market glyphs come from the game's own cargo tabs and material data (cardboardBox / smallTrailer / keys1 / droplet / rocks).
const MARKET_ICONS = { parcels: 'cardboardBox', trailers: 'smallTrailer', liquids: 'droplet', bulk: 'rocks', cars: 'keys1', specialty: 'concreteRoadBlock' }
const marketIcon = id => icons[MARKET_ICONS[id]] || icons.cardboardBox
// Vanilla vehicle previews stand in for each market (served from the game's vehicle content).
const MARKET_IMAGES = { parcels: '/vehicles/md_series/md_60_cargobox.jpg', trailers: '/vehicles/dryvan/53ft.jpg', liquids: '/vehicles/tanker/diesel_3.jpg', bulk: '/vehicles/us_semi/t83s_dump.jpg', cars: '/vehicles/us_semi/t83s_rollback.jpg', specialty: '/vehicles/us_semi/t83s_mixer.jpg' }
const marketImage = id => MARKET_IMAGES[id] || MARKET_IMAGES.parcels
const loadCount = value => value + (value === 1 ? ' load' : ' loads')
const money = value => '$' + Math.round(Number(value) || 0).toLocaleString()
const rate = value => '$' + Number(value || 0).toLocaleString(undefined, {minimumFractionDigits: 2, maximumFractionDigits: 2})
function dist(value) { if (value == null) return '—'; // the game formatter auto-scales tiny values to mm/cm; keep short hops at whole metres
  const v = Math.max(Number(value) || 0, 1); const p = value < 1000 ? 0 : 1; return units?.buildString ? units.buildString('length', v, p) : value < 1000 ? Math.round(value) + ' m' : (value / 1000).toFixed(1) + ' km' }
function isMarketFilterActive(id) {
  const selected = s.filter.markets || []
  return !selected.length || selected.includes(id)
}
const tableColumns = [
  { key: 'load', label: 'Load / route', span: 2, start: true, ascLabel: 'Sort load name A to Z', descLabel: 'Sort load name Z to A' },
  { key: 'pickup', label: 'Pickup', hint: 'Distance to pickup', ascLabel: 'Sort nearest pickup first', descLabel: 'Sort farthest pickup first' },
  { key: 'haul', label: 'Haul', ascLabel: 'Sort shortest haul first', descLabel: 'Sort longest haul first' },
  { key: 'cargo', label: 'Cargo', hint: 'Cargo or trailer type', ascLabel: 'Sort cargo A to Z', descLabel: 'Sort cargo Z to A' },
  { key: 'pay', label: 'Pay', ascLabel: 'Sort lowest pay first', descLabel: 'Sort highest pay first' },
]
const COLUMN_SORTS = {
  load: { asc: 'titleAz', desc: 'titleZa' },
  pickup: { asc: 'near', desc: 'pickupFar' },
  haul: { asc: 'short', desc: 'long' },
  cargo: { asc: 'cargoAz', desc: 'cargoZa' },
  pay: { asc: 'payAsc', desc: 'pay' },
}
function setColumnSort(column, direction) {
  const next = COLUMN_SORTS[column]?.[direction]
  if (next) s.updateFilter('sort', next)
}
function columnSortActive(column, direction) {
  return COLUMN_SORTS[column]?.[direction] === s.filter.sort
}
function toggleMarketFilter(id) {
  const selected = [...(s.filter.markets || [])]
  const allIds = markets.map(m => m.id)
  let next
  if (!selected.length) {
    next = allIds.filter(x => x !== id)
  } else if (selected.includes(id)) {
    next = selected.filter(x => x !== id)
  } else {
    next = [...selected, id]
  }
  if (next.length === 0 || next.length === allIds.length) next = []
  s.updateFilter('markets', next)
}
function capacityText(row) { return Object.values(row.capacity || {}).map(c => `${Number(c.amount || 0).toLocaleString()} ${{parcel:'slots',fluid:'L liquid',dryBulk:'L bulk',cement:'L concrete',cash:'secure units'}[c.type] || c.type}`).join(', ') }
function fact(row) { return row.trailerType || `${Number(row.quantity || 0).toLocaleString()} ${row.unit || ''}` }
function pct(part) { const r = s.selectedRow; const total = (r?.delivered || 0) + (r?.inTransit || 0) + (r?.remaining || 0); return total ? (100 * (Number(part) || 0) / total).toFixed(1) + '%' : '0%' }
// Requirement strings arrive as "Enclosed cargo · Logistics level 8"; show them as labelled facts instead.
// Listed pay includes the Logistics level bonus the drop-off adds; clean-delivery bonuses come on top.
const payOf = row => Number(row?.estimatedPay ?? row?.pay) || 0
const detailFacts = computed(() => {
  const r = s.selectedRow; if (!r) return []
  const parts = String(r.requirement || '').split(/\s*[\u00b7\u2022|]\s*/).map(x => x.trim()).filter(Boolean)
  let level = null
  const needs = parts.filter(x => { const m = x.match(/logistics\s+level\s+(\d+)/i); if (m) { level = m[1]; return false } return true })
  const out = [{ k: 'Cargo', v: fact(r) }]
  if (level) out.push({ k: 'Logistics', v: 'Lv ' + level, icon: icons.deliveryTruck })
  if (needs.length) out.push({ k: 'Needs', v: needs.join(', ') })
  out.push({ k: 'Equipment', v: r.arrangement === 'supplied' ? 'Trailer supplied' : 'Bring your own', cls: r.arrangement === 'supplied' ? 'accent' : '' })
  if (Number(r.levelBonus) > 0) {
    out.push({ k: 'Base pay', v: money(r.basePay ?? r.pay) })
    out.push({ k: 'Level bonus', v: '+' + Math.round(r.levelBonus * 100) + '%', cls: 'accent' })
  }
  return out
})
// The dropdown list is teleported outside the phone, so it misses the phone's scale; size it from the trigger.
function syncDropdownFont() {
  const apply = () => {
    const trig = document.querySelector('.broker .bng-dropdown.broker-dropdown'); if (!trig || !trig.offsetHeight) return
    const px = parseFloat(getComputedStyle(trig).fontSize) * (trig.getBoundingClientRect().height / trig.offsetHeight)
    document.querySelectorAll('.bng-dropdown-content.broker-dropdown').forEach(el => { el.style.fontSize = px.toFixed(2) + 'px' })
  }
  nextTick(apply); setTimeout(apply, 60)
}
function legDistance(stop) { const leg = (s.data.route?.legs || []).find(l => l.stopId === stop.id); return leg && leg.distance != null ? dist(leg.distance) : '—' }
function statusName(value) { return ({ reserved: 'Reserved', active: 'In progress', complete: 'Delivered' })[value] || value }
function rememberScroll() { if (listEl.value) s.scrolls[s.view + ':' + s.market] = listEl.value.scrollTop }
async function closeDetail() { s.selected = null; await nextTick(); if (listEl.value) listEl.value.scrollTop = s.scrolls[s.view + ':' + s.market] || 0 }
function select(row) { confirmingAbandon.value = false; rememberScroll(); s.selected = row.id; container.value = ''; selectedCars.value = [] }
function refreshContainers() {
  if (containerLoading.value) return
  const request = ++containerRequest
  containerLoading.value = true; containerError.value = ''; container.value = ''; s.containers = []
  containerTimer = setTimeout(() => {
    if (request !== containerRequest) return
    containerLoading.value = false
    containerError.value = 'Cargo scan timed out. Try Refresh equipment.'
  }, 8000)
  callModLua('ui_phone_logistics.requestBrokerContainers').catch(() => {
    if (request !== containerRequest) return
    clearTimeout(containerTimer); containerLoading.value = false
    containerError.value = 'Could not read nearby cargo space. Try Refresh equipment.'
  })
}
watch([() => s.selectedRow?.id, () => s.selectedRow?.atPickup], () => {
  clearTimeout(containerTimer); containerRequest++; containerLoading.value = false
  container.value = ''; s.containers = []; containerError.value = ''
  if (s.selectedRow?.atPickup && ['parcel', 'material'].includes(s.selectedRow.kind)) refreshContainers()
})
function receiveContainers(data) {
  if (!s.selectedRow?.atPickup || !['parcel', 'material'].includes(s.selectedRow.kind)) return
  clearTimeout(containerTimer); containerRequest++; containerLoading.value = false; containerError.value = ''
  s.containers = Object.values(data || {})
  if (!s.containers.some(c => c.key === container.value)) container.value = ''
}
// Bulk parcel loading: every reserved parcel waiting at this pickup is listed, split across the nearby
// boxes by slot size (largest parcel first, into the tightest box it fits), and loaded with one commit.
// Tapping a box chip moves one parcel to the next box with room; unticking leaves parcels at the pickup.
// Reserving from a "6×" group: pick how many identical offers to take (defaults to all of them).
const reserveAmount = ref(1)
const reserveGroup = computed(() => s.selectedRow && !s.selectedRow.status ? (selectedListRow.value?.groupCount || 1) : 1)
const reserveMax = computed(() => Math.max(1, reserveGroup.value))
const reserveSlots = n => s.selectedRow?.unit === 'slots' ? `${n * slotsOf(s.selectedRow)} slots` : `${n} ${n === 1 ? 'load' : 'loads'}`
watch(() => [s.selected, reserveMax.value], () => { reserveAmount.value = reserveMax.value })
function stepReserve(delta) { reserveAmount.value = Math.min(reserveMax.value, Math.max(1, reserveAmount.value + delta)) }
function reserveSelected() {
  const r = s.selectedRow
  if (!r) return
  reserveAmount.value = Math.min(reserveMax.value, Math.max(1, reserveAmount.value))
  if (reserveAmount.value <= 1) { s.action('reserve', { id: r.id, signature: r.signature }); return }
  const ids = [r.id, ...(selectedListRow.value?.groupOfferIds || []).filter(id => id !== r.id)].slice(0, reserveAmount.value)
  const items = ids.map(id => ({ id, signature: (s.data.offers.find(o => o.id === id) || {}).signature })).filter(i => i.signature)
  s.action('reserveMany', { items })
}
const loadPlan = ref({}), loadSkip = ref({})
const showLoader = computed(() => !!(s.selectedRow?.atPickup && s.selectedRow.kind === 'parcel' && pickupParcels.value.length))
const slotsOf = j => Math.max(0, Number(j?.quantity) || 0)
const pickupKey = j => j?.origin?.facId || j?.from || ''
const pickupParcels = computed(() => {
  const r = s.selectedRow
  if (!r || r.kind !== 'parcel' || !r.atPickup || (r.status && r.status !== 'reserved')) return []
  const here = j => j.kind === 'parcel' && j.atPickup && j.unlocked !== false && pickupKey(j) === pickupKey(r)
  const jobs = activeJobs.value.filter(j => here(j) && j.status === 'reserved')
  // Browsing the market at the pickup: parcels on offer here can be loaded straight away ("Load now").
  const offers = r.status ? [] : (s.data.offers || []).filter(o => here(o) && !o.status)
  const list = [...jobs, ...offers]
  return [...list.filter(j => j.id === r.id), ...list.filter(j => j.id !== r.id)]
})
const parcelBoxes = computed(() => s.containers.filter(c => !c.types || c.types.parcel))
const boxByKey = key => parcelBoxes.value.find(c => c.key === key)
// All boxes on one vehicle: name it once above the boxes instead of on every row.
const loadVehicle = computed(() => { const names = new Set(parcelBoxes.value.map(c => c.vehName || '')); return names.size === 1 ? [...names][0] : '' })
const boxIndex = key => parcelBoxes.value.findIndex(c => c.key === key)
const boxCap = c => Math.max(Number(c.capacity) || 0, Number(c.free) || 0)
const boxHeld = c => Math.max(0, boxCap(c) - (Number(c.free) || 0))
const boxUse = (key, except) => pickupParcels.value.reduce((n, j) => n + (j.id !== except && !loadSkip.value[j.id] && loadPlan.value[j.id] === key ? slotsOf(j) : 0), 0)
const boxLeft = c => (Number(c.free) || 0) - boxUse(c.key)
const roomFor = (c, j) => (Number(c.free) || 0) - boxUse(c.key, j.id) >= slotsOf(j)
const canMove = j => parcelBoxes.value.some(c => c.key !== loadPlan.value[j.id] && roomFor(c, j))
const share = (n, of) => of > 0 ? `${Math.min(100, Math.max(0, (n / of) * 100))}%` : '0%'
// Short box names ("Cargo Box") unless two vehicles carry the same one, then the full "Vehicle Box" label.
function boxLabel(c) {
  if (!c) return ''
  const short = c.boxName || c.name
  return parcelBoxes.value.filter(x => (x.boxName || x.name) === short).length > 1 ? c.name : short
}
function autoSplit() {
  const plan = {}, left = Object.fromEntries(parcelBoxes.value.map(c => [c.key, Number(c.free) || 0]))
  const queue = pickupParcels.value.filter(j => !loadSkip.value[j.id]).sort((a, b) => slotsOf(b) - slotsOf(a))
  for (const j of queue) {
    const fit = parcelBoxes.value.filter(c => left[c.key] >= slotsOf(j)).sort((a, b) => left[a.key] - left[b.key])[0]
    plan[j.id] = fit ? fit.key : ''
    if (fit) left[fit.key] -= slotsOf(j)
  }
  loadPlan.value = plan
}
function cycleBox(j) {
  const boxes = parcelBoxes.value, at = boxIndex(loadPlan.value[j.id])
  for (let step = 1; step <= boxes.length; step++) {
    const c = boxes[(at + step + boxes.length) % boxes.length]
    if (roomFor(c, j)) { loadPlan.value = { ...loadPlan.value, [j.id]: c.key }; return }
  }
}
// Identical parcels (same title, route, pay and slot size) show as one "3×" row like the load list.
// Each parcel is still its own job, so a group can be split: some in one box, the rest in another.
const pickupGroups = computed(() => groupBrokerRows(pickupParcels.value, { byStatus: true }))
const jobOf = id => pickupParcels.value.find(j => j.id === id)
const groupJobs = g => g.groupOfferIds.map(jobOf).filter(Boolean)
const groupLoad = g => groupJobs(g).filter(j => !loadSkip.value[j.id]).length
const groupStuck = g => groupJobs(g).filter(j => !loadSkip.value[j.id] && !boxByKey(loadPlan.value[j.id])).length
function groupSplits(g) {
  const by = new Map()
  for (const j of groupJobs(g)) {
    const key = loadPlan.value[j.id]
    if (loadSkip.value[j.id] || !boxByKey(key)) continue
    const entry = by.get(key) || { key, n: 0, job: j }
    entry.n++; entry.job = j; by.set(key, entry)
  }
  return [...by.values()].sort((a, b) => boxIndex(a.key) - boxIndex(b.key))
}
// Keep a parcel in its box if it still fits, otherwise put it in the tightest box with room.
function fitJob(j) {
  const cur = boxByKey(loadPlan.value[j.id])
  if (cur && roomFor(cur, j)) return
  const fit = parcelBoxes.value.filter(c => roomFor(c, j)).sort((a, b) => boxLeft(a) - boxLeft(b))[0]
  loadPlan.value = { ...loadPlan.value, [j.id]: fit ? fit.key : '' }
}
function setSkip(j, skip) { loadSkip.value = { ...loadSkip.value, [j.id]: skip }; if (!skip) fitJob(j) }
function toggleGroup(g) { const on = groupLoad(g) > 0; for (const j of groupJobs(g)) setSkip(j, on) }
function stepGroup(g, delta) {
  const jobs = groupJobs(g)
  if (delta > 0) { const j = jobs.find(x => loadSkip.value[x.id]); if (j) setSkip(j, false); return }
  const on = jobs.filter(x => !loadSkip.value[x.id])
  const j = on.find(x => !boxByKey(loadPlan.value[x.id])) || on[on.length - 1]
  if (j) setSkip(j, true)
}
const loadItems = computed(() => pickupParcels.value.filter(j => !loadSkip.value[j.id] && boxByKey(loadPlan.value[j.id])))
watch(() => [s.selectedRow?.id, s.selectedRow?.status], () => {
  const keep = new Set(selectedListRow.value?.groupOfferIds || [s.selectedRow?.id])
  loadSkip.value = Object.fromEntries(pickupParcels.value.filter(j => !j.status && !keep.has(j.id)).map(j => [j.id, true]))
  autoSplit()
})
watch(() => [parcelBoxes.value.map(c => `${c.key}:${c.free}`).join(','), pickupParcels.value.map(j => j.id).join(',')], autoSplit)
// Parcels leaving the pickup list (loaded, or a skipped one left behind) change box space: rescan.
watch(() => [s.selectedRow?.id, pickupParcels.value.map(j => j.id).join(',')], ([id, now], [idBefore, before] = []) => {
  if (id === idBefore && now !== before && now) refreshContainers()
})
function loadParcels() {
  const picked = loadItems.value
  if (!picked.length) return
  if (picked.every(j => j.status)) { s.action('pickupBatch', { items: picked.map(j => ({ id: j.id, container: loadPlan.value[j.id] })) }); return }
  s.action('loadHere', { items: picked.map(j => j.status ? { id: j.id, container: loadPlan.value[j.id] } : { offer: j.id, signature: j.signature, container: loadPlan.value[j.id] }) })
}
// Label and hint for the load button, shared by My Loads (reserved) and the market ("Load now").
const loadStep = computed(() => {
  if (!parcelBoxes.value.length) return { label: 'No cargo space nearby', hint: 'Bring a vehicle with room for this cargo', disabled: true }
  const items = loadItems.value, slots = items.reduce((n, j) => n + slotsOf(j), 0), boxes = new Set(items.map(j => loadPlan.value[j.id])).size
  const stuck = pickupParcels.value.filter(j => !loadSkip.value[j.id] && !loadPlan.value[j.id]).length
  const total = pickupParcels.value.length, loads = pickupGroups.value.filter(g => groupLoad(g)).length
  const market = !s.selectedRow?.status
  // In My Loads the button covers every parcel reserved here, not just the selected load, so say so.
  const label = !items.length ? 'Nothing to load' : market ? `Load ${items.length === 1 ? 'parcel' : items.length + ' parcels'} now` : total === 1 ? 'Load parcel' : items.length === total ? (total === 2 ? 'Load both parcels' : `Load all ${total} parcels`) : `Load ${items.length} of ${total} parcels`
  const into = `${slots} ${slots === 1 ? 'slot' : 'slots'} into ${boxes === 1 ? boxLabel(boxByKey(loadPlan.value[items[0]?.id])) : boxes + ' boxes'}`
  return { label, disabled: !items.length,
    hint: !items.length ? 'Tick the parcels to load' : `${loads > 1 ? `${loads} loads, ` : ''}${into}${stuck ? `, ${stuck} won't fit` : ''}` }
})
// A "3×" row in My Loads is several identical jobs: cancel or abandon the whole group at once.
const groupJobIds = computed(() => {
  const ids = s.selectedRow?.status ? selectedListRow.value?.groupOfferIds : null
  return ids?.length ? ids : (s.selected ? [s.selected] : [])
})
const groupFine = computed(() => groupJobIds.value.reduce((n, id) => n + (Number(s.data.jobs.find(j => j.id === id)?.abandonFine) || 0), 0))
async function cancelReservation() {
  const ids = groupJobIds.value
  if (!ids.length) return
  const result = ids.length > 1 ? await s.action('cancelMany', { ids }) : await s.action('cancel', { id: ids[0] })
  if (result?.ok && ids.includes(s.selected)) s.selected = null
}
async function abandon() {
  if (!confirmingAbandon.value) { confirmingAbandon.value = true; return }
  const ids = groupJobIds.value
  const result = ids.length > 1 ? await s.action('abandonMany', { ids }) : await s.action('abandon', { id: ids[0] })
  if (result?.ok) s.selected = null
  confirmingAbandon.value = false
}
function collect() { s.action('pickup', { id: s.selected, amount: amount.value, container: container.value, cars: selectedCars.value }) }
// The orange button is always the next thing to do for this load, so the job reads as a guided
// sequence: drive to the pickup, stage / bring out / load, drive to the delivery, hand over.
const nextStep = computed(() => {
  const r = s.selectedRow
  if (!r || !r.status || r.status === 'complete') return null
  const nav = leg => () => s.action('navigate', { id: r.id, leg })
  const cars = r.vehicles || []
  const pendingCars = cars.filter(c => !c.status || c.status === 'pending')
  const stagedCars = cars.filter(c => c.status === 'staged')
  let needsPickup
  if (r.kind === 'cars') needsPickup = !stagedCars.length && (pendingCars.length > 0 || !cars.length)
  else if (r.kind === 'trailer') needsPickup = r.status === 'reserved'
  else needsPickup = r.status === 'reserved' || (!(Number(r.inTransit) > 0) && Number(r.remaining) > 0)
  if (needsPickup) {
    if (!r.atPickup) return { key: 'toPickup', label: 'Navigate to pickup', hint: `Drive to ${r.from || 'the pickup'}`, run: nav('pickup') }
    if (r.kind === 'cars') {
      const picked = selectedCars.value.filter(k => pendingCars.some(c => c.key === k))
      const count = picked.length || pendingCars.length
      return { key: 'stage', label: count === 1 ? 'Stage the vehicle' : picked.length ? `Stage ${count} vehicles` : `Stage all ${count} vehicles`, hint: 'Stage the cars at the lot, then load them on your hauler', disabled: !count,
        run: () => { if (!picked.length) selectedCars.value = pendingCars.map(c => c.key); collect() } }
    }
    if (r.kind === 'trailer') return { key: 'collect', label: 'Bring out the trailer', hint: 'The trailer is placed in the pickup bay for you to hook up', run: collect }
    if (r.kind === 'parcel') return { key: 'load', ...loadStep.value, run: loadParcels }
    const con = s.containers.find(c => c.key === container.value)
    if (!s.containers.length) return { key: 'load', label: 'No cargo space nearby', hint: 'Bring a vehicle with room for this cargo', disabled: true, run: collect }
    return { key: 'load', label: 'Load cargo', hint: con ? `Loads into ${con.name}` : 'Pick a cargo space above', disabled: !con || (r.kind === 'material' && !validAmount.value), run: collect }
  }
  if (r.atDelivery) return { key: 'deliver', label: 'Navigate to delivery', hint: 'You are here. Hand over at the drop-off marker', run: nav('delivery') }
  return { key: 'toDelivery', label: 'Navigate to delivery', hint: r.kind === 'cars' && stagedCars.length ? `Load the staged cars, then drive to ${r.to || 'the delivery'}` : r.kind === 'trailer' ? `Hook up the trailer, then drive to ${r.to || 'the delivery'}` : `Deliver to ${r.to || 'the delivery'}`, run: nav('delivery') }
})
// With a single usable cargo space there is nothing to choose: preselect it.
watch(() => [s.selected, s.containers.length], () => { if (!container.value && s.containers.length) { const c = s.containers.find(x => Number(x.free) > 0) || s.containers[0]; if (c) container.value = c.key } })
function toggleCar(key) { selectedCars.value = selectedCars.value.includes(key) ? selectedCars.value.filter(k => k !== key) : [...selectedCars.value, key] }
function toggleTrailer(type) { s.updateFilter('trailers', s.filter.trailers.includes(type) ? s.filter.trailers.filter(v => v !== type) : [...s.filter.trailers, type]) }
watch(radiusPresets, presets => {
  const r = s.filter.radius
  if (!r || !presets.length) return
  const max = presets[presets.length - 1].value
  if (r > max) s.updateFilter('radius', max)
}, { immediate: true })
watch([pickupLocationOptions, destLocationOptions], () => {
  if (s.filter.pickupFac && !pickupLocationOptions.value.some(o => o.value === s.filter.pickupFac)) {
    s.updateFilter('pickupFac', '')
  }
  if (s.filter.destFac && !destLocationOptions.value.some(o => o.value === s.filter.destFac)) {
    s.updateFilter('destFac', '')
  }
})
function isSaved(row) { return Object.values(s.data.plans).some(p => p.id === row.id || p.offerId === row.id) }
function stopJob(stop) { return s.data.jobs.find(j => j.id === stop.jobId) || s.data.plans[stop.jobId] }
function openStop(stop) { const row = stopJob(stop); if (!row) return; s.selected = row.id; jobsTab.value = 'loads'; if (row.status) s.action('navigate', { id: row.id, leg: stop.kind, stopId: stop.id }) }
function back() { if (s.selected) { closeDetail(); return true } if (s.view !== 'markets') { s.view = 'markets'; return true } return false }
onMounted(async () => {
  events.on('phoneBrokerState', s.receive); events.on('phoneBrokerResult', s.receiveResult); events.on('phoneBrokerContainers', receiveContainers)
  await callModLua('extensions.load', 'ui_phone_logistics'); await s.refresh()
  const context = s.data.openContext || {}
  if (context.facility) { s.scope = context.facility; s.chooseMarket('all'); s.expanded = true }
  if (context.depot) { s.view = 'loaners'; s.expanded = true }
  if (context.tab === 'jobs') { s.view = 'jobs'; s.expanded = true }
  // Harness / deep links: open expanded, on a market, on a view, or with a load selected.
  if (context.market) s.chooseMarket(context.market)
  if (['loads', 'jobs', 'loaners', 'filters', 'markets'].includes(context.view)) s.view = context.view
  if (context.select) s.selected = context.select
  if (context.routeTab) jobsTab.value = 'route'
  if (context.expanded) s.expanded = true
  refreshTimer = setInterval(() => { if (!working.value) s.refresh() }, 10000)
  if (route.query.facility) { s.scope = String(route.query.facility); s.chooseMarket('all'); s.expanded = true }
  if (route.query.depot) { s.view = 'loaners'; s.expanded = true }
})
onUnmounted(() => { clearInterval(refreshTimer); clearTimeout(containerTimer); containerRequest++; events.off('phoneBrokerState', s.receive); events.off('phoneBrokerResult', s.receiveResult); events.off('phoneBrokerContainers', receiveContainers) })
</script>

<style scoped>
/* House style shared with EmployeeShift: dark gray, orange accent, Overpass, soft corners, no stripes. */
.broker { --accent: var(--bng-orange-b400, #ff6600); --panel: rgba(255, 255, 255, 0.06); --panel-2: rgba(255, 255, 255, 0.1); --line: rgba(255, 255, 255, 0.1); --muted: rgba(255, 255, 255, 0.72); --faint: rgba(255, 255, 255, 0.55); --money: #fde68a; --ok: #4ade80;
  height: 100%; box-sizing: border-box; padding-top: 4.2em; display: flex; flex-direction: column; position: relative; background: #151517; color: #fff; font-family: "Overpass", var(--fnt-defs, sans-serif); font-size: 12px; line-height: 1.35; --bng-icon-color: currentColor; }
.broker.expanded { font-size: clamp(0.8rem, calc(1.3vh * var(--ui-scale, 1)), 1.5rem); }
.broker * { box-sizing: border-box; }
.broker :deep(.bng-icon) { font-size: 1.25em; }

/* ---- buttons and fields */
.broker button, .broker input, .broker select { font: inherit; color: inherit; background: var(--panel-2); border: 0; border-radius: 0.6em; padding: 0.62em 0.95em 0.5em; line-height: 1; }
.broker button { cursor: pointer; font-weight: 700; white-space: nowrap; transition: background-color 0.12s, transform 0.08s; }
.broker button:hover:not(:disabled) { background: rgba(255, 255, 255, 0.16); }
.broker button:active:not(:disabled) { transform: translateY(1px); }
.broker button:focus-visible, .broker input:focus-visible { outline: none; box-shadow: 0 0 0 2px #fff, 0 0 0 4px rgba(255, 102, 0, 0.7); }
.broker button:disabled { opacity: 0.45; cursor: default; }
.broker .primary { background: var(--accent); color: #fff; }
.broker .primary:hover:not(:disabled) { background: #ff7a1f; }
.broker input { background: rgba(0, 0, 0, 0.3); border: 1px solid var(--line); border-radius: 0.5em; padding: 0.6em 0.8em; font-weight: 400; }
.broker input::placeholder { color: var(--faint); }
.text-btn { background: none !important; padding: 0.3em 0 !important; color: var(--accent) !important; font-weight: 700; }
.text-btn:hover:not(:disabled) { background: none !important; color: #ff9a4d !important; }
.icon-btn { display: grid; place-items: center; width: 2.4em; height: 2.4em; padding: 0 !important; }
.block-head { display: flex; align-items: center; gap: 0.45em; }
.tip-btn { position: relative; display: grid; place-items: center; width: 1.75em; height: 1.75em; padding: 0 !important; border-radius: 50%; background: transparent !important; color: var(--faint) !important; transition: color 0.12s, background-color 0.12s; }
.tip-btn svg { width: 1em; height: 1em; fill: none; stroke: currentColor; stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; }
.tip-btn:hover:not(:disabled), .tip-btn:focus-visible { color: #fff !important; background: var(--panel-2) !important; }
.tip-btn:disabled { opacity: 0.6; }
.tip-btn.spinning svg { animation: tip-spin 0.9s linear infinite; }
.tip-btn::after { content: attr(data-tip); position: absolute; left: calc(100% + 0.45em); top: 50%; transform: translate(-0.3em, -50%); padding: 0.42em 0.65em 0.28em; border-radius: 0.35em; background: #2b2c30; color: #fff; font-size: 0.72em; font-weight: 700; letter-spacing: 0.02em; white-space: nowrap; box-shadow: 0 4px 14px rgba(0, 0, 0, 0.55); opacity: 0; pointer-events: none; transition: opacity 0.12s ease-out, transform 0.12s ease-out; z-index: 5; }
.tip-btn:hover::after, .tip-btn:focus-visible::after { opacity: 1; transform: translate(0, -50%); }
@keyframes tip-spin { to { transform: rotate(360deg); } }
.icon-btn svg { width: 1.15em; height: 1.15em; fill: none; stroke: currentColor; stroke-width: 2; stroke-linecap: round; stroke-linejoin: round; }
.pill { display: inline-flex; align-items: center; gap: 0.25em; width: fit-content; justify-self: start; padding: 0.3em 0.55em 0.2em; border-radius: 0.3em; background: var(--panel-2); color: rgba(255, 255, 255, 0.8); font-size: 0.78em; font-weight: 700; line-height: 1; white-space: nowrap; }
.pill.accent { background: rgba(255, 102, 0, 0.25); color: #ffb27a; }
.pill.muted { background: transparent; color: var(--faint); padding-left: 0; }
.kicker { font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--accent); }
.hint, .muted { color: var(--muted); }
.money { color: var(--money); }

/* ---- header */
.apphead { display: flex; justify-content: space-between; align-items: center; gap: 0.75em; padding: 0.4em 1em 0.6em; flex-shrink: 0; }
.apphead h2 { margin: 0; font-size: 1.55em; font-weight: 800; font-style: italic; letter-spacing: -0.01em; line-height: 1.1; }
.scroll { overflow: auto; min-height: 0; flex: 1; scrollbar-gutter: stable; }
.scroll::-webkit-scrollbar { width: 0.45em; height: 0.45em; }
.scroll::-webkit-scrollbar-track { background: transparent; }
.scroll::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: 1em; border: 0.1em solid transparent; background-clip: padding-box; }
.scroll::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }

/* ---- markets */
.market-body { padding: 0 1em 1em; }
.intro { margin: 0 0 0.75em; color: var(--muted); }
.market-grid { display: grid; grid-template-columns: 1fr; gap: 0.5em; }
.market-tile { display: flex; align-items: center; gap: 0.7em; width: 100%; text-align: left; padding: 0.7em 0.8em 0.7em 0.75em !important; border-radius: 0.5em !important; background: var(--panel) !important; font-weight: 400; }
.market-tile:hover:not(:disabled) { background: var(--panel-2) !important; }
.market-tile.last { box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.55); }
.market-tile .tile-img { position: relative; flex: 0 0 auto; width: 5.2em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35); }
.market-tile .tile-img img { display: block; width: 100%; height: 100%; object-fit: cover; }
.market-tile .tile-img::after { content: ""; position: absolute; inset: 0; background: linear-gradient(to top right, rgba(20, 20, 22, 0.7), rgba(20, 20, 22, 0) 60%); pointer-events: none; }
.market-tile .tile-glyph { position: absolute; left: 0.3em; bottom: 0.2em; font-size: 1.1em; color: #fff; filter: drop-shadow(0 1px 2px rgba(0, 0, 0, 0.9)); }
.market-tile .tile-copy { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.15em; }
.market-tile strong { font-size: 1.1em; line-height: 1.15; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.market-tile .tile-copy span { color: var(--muted); font-size: 0.9em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.market-tile .pill { flex: 0 0 auto; }
.browse-all { width: 100%; display: flex; justify-content: space-between; align-items: center; margin-top: 0.6em; padding: 0.8em 0.9em !important; }
.browse-all .pill { font-size: 0.8em; }

/* ---- bottom nav */
.nav { display: flex; justify-content: space-around; gap: 0.25em; padding: 0.35em 0.5em 0.5em; border-top: 1px solid var(--line); background: rgba(0, 0, 0, 0.25); flex-shrink: 0; }
.nav button { position: relative; flex: 1 1 0; display: flex; flex-direction: column; align-items: center; gap: 0.25em; padding: 0.55em 0.4em 0.5em; background: transparent !important; color: var(--muted); font-size: 0.85em; font-weight: 600; }
.nav button :deep(.bng-icon) { font-size: 1.7em; }
.nav button.active { color: #fff; }
.nav button.active::after { content: ""; position: absolute; left: 50%; bottom: 0; width: 2.4em; height: 3px; border-radius: 3px; background: var(--accent); transform: translateX(-50%); }

/* ---- loads: toolbar, list, rows */
.toolbar { padding: 0 1em 0.5em; flex-shrink: 0; display: grid; gap: 0.45em; }
.breadcrumb { display: flex; justify-content: space-between; align-items: center; }
.toolbar input { width: 100%; }
.toolbar-row { display: flex; gap: 0.4em; align-items: center; }
.toolbar-row .broker-dropdown { flex: 1; width: auto; min-width: 0; }
.toolbar-row .icon-btn { flex: 0 0 auto; }
.jobs-tabs { display: flex; gap: 0.4em; padding: 0 1em 0.5em; }
.jobs-tabs button { flex: 1; background: var(--panel); }
.jobs-tabs button.active { background: var(--panel-2); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.55); }
.workarea { flex: 1; min-height: 0; display: flex; }
.load-list { padding: 0 1em 0.75em; }
.list-caption { display: flex; justify-content: space-between; margin: 0.2em 0 0.5em; font-size: 0.78em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--faint); }
.row-thumb { flex: 0 0 auto; width: 4.6em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35); display: grid; place-items: center; color: rgba(255, 255, 255, 0.45); }
.row-thumb img { display: block; width: 100%; height: 100%; object-fit: cover; }
.row-thumb :deep(.bng-icon) { font-size: 1.6em; }
.load-row { display: flex; align-items: center; gap: 0.7em; width: 100%; text-align: left; margin: 0 0 0.4em; padding: 0.6em 0.75em !important; border-radius: 0.5em !important; background: var(--panel) !important; font-weight: 400; white-space: normal; }
.load-row:hover:not(:disabled) { background: var(--panel-2) !important; }
.load-row.selected { box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.6); background: rgba(255, 102, 0, 0.1) !important; }
.row-summary { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.2em; }
.card-top { display: flex; justify-content: space-between; align-items: baseline; gap: 0.6em; }
.card-top h3 { margin: 0; font-size: 1.05em; font-weight: 700; line-height: 1.2; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.group-mult { margin-right: 0.35em; color: #ffb27a; font-weight: 800; letter-spacing: 0.02em; }
.detail-hero-copy h2 .group-mult { margin-right: 0.25em; }
.pay { color: var(--money); font-weight: 700; white-space: nowrap; }
.route { color: var(--muted); font-size: 0.92em; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.row-bottom { display: flex; justify-content: space-between; gap: 0.6em; font-size: 0.85em; color: var(--faint); }
.row-bottom span:last-child { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.row-meta { display: inline-flex; gap: 0.8em; }
.row-meta > span { display: inline-flex; align-items: center; gap: 0.25em; color: var(--muted); font-weight: 700; }
.row-meta :deep(.bng-icon) { font-size: 1.15em; color: var(--faint); }
.load-row .status { margin-top: 0.35em; }
.list-columns, .wide-cell, .detail-placeholder { display: none; }
.empty { padding: 2em 1em; text-align: center; color: var(--muted); flex: 1; display: grid; gap: 0.6em; justify-items: center; align-content: center; }
.empty-badge { display: grid; place-items: center; width: 3.6em; height: 3.6em; border-radius: 50%; background: var(--panel-2); color: #ffb27a; margin-bottom: 0.3em; }
.empty-badge :deep(.bng-icon) { font-size: 2.1em; }
.employed-state .employed-copy { margin: 0; font-size: 1.15em; font-weight: 700; line-height: 1.35; max-width: 18em; color: #fff; }
.employed-state button { margin-top: 0.6em; padding: 0.75em 1.4em 0.6em; }
.empty h3 { margin: 0; color: #fff; }
.empty p { margin: 0; }

/* ---- detail */
.detail-pane { display: flex; flex: 1; min-width: 0; flex-direction: column; }
.detail-scroll { padding: 0 1em 1em; }
.detail-hero { position: relative; margin: 0.5em 0 0; border-radius: 0.5em; overflow: hidden; aspect-ratio: 16 / 8; background: rgba(0, 0, 0, 0.35); }
.detail-hero.no-photo { aspect-ratio: auto; min-height: 5.5em; }
.detail-hero img { display: block; width: 100%; height: 100%; object-fit: cover; }
.detail-hero::after { content: ""; position: absolute; inset: 0; background: linear-gradient(to top, rgba(21, 21, 23, 1) 0%, rgba(21, 21, 23, 0.55) 40%, rgba(21, 21, 23, 0) 75%); pointer-events: none; }
.detail-hero-copy { position: absolute; left: 0.8em; right: 8em; bottom: 0.55em; z-index: 1; }
.detail-hero-pay { position: absolute; right: 0.8em; bottom: 0.7em; z-index: 1; display: grid; justify-items: end; gap: 0.3em; }
.detail-hero-pay .detail-pay { font-size: 1.6em; text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9); }
.detail-hero-copy .eyebrow { margin: 0; text-shadow: 0 1px 2px rgba(0, 0, 0, 0.9); }
.detail-hero-copy h2 { margin: 0.1em 0 0; text-shadow: 0 1px 3px rgba(0, 0, 0, 0.9); }
.detail-close { position: absolute; top: 0.6em; right: 0.6em; z-index: 2; background: rgba(0, 0, 0, 0.55) !important; }
.detail-close:hover:not(:disabled) { background: rgba(0, 0, 0, 0.75) !important; }
.facts { display: grid; grid-template-columns: repeat(auto-fit, minmax(min(7em, 100%), 1fr)); gap: 0.4em 0.9em; margin-top: 0.6em; padding: 0.6em 0.75em; border-radius: 0.5em; background: var(--panel); }
.fact { display: grid; gap: 0.15em; min-width: 0; }
.fact-key { font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
.fact-value { font-weight: 700; line-height: 1.25; display: inline-flex; align-items: center; gap: 0.3em; overflow-wrap: anywhere; }
.fact-value.accent { color: #ffb27a; }
.count { margin-left: 0.45em; font-size: 0.72em; }
.pay-note { margin: 0.5em 0 0; font-size: 0.8em; font-weight: 600; line-height: 1.35; color: var(--faint); }
.fact-value :deep(.bng-icon) { font-size: 1.15em; }
.detail-map-slot { flex: 1 1 8em; min-height: 8em; padding: 0.5em 1em 0; display: flex; }
.detail-map-slot .detail-map { flex: 1 1 auto; aspect-ratio: auto; height: auto; min-height: 7em; }
.detail-scroll { flex: 1 1 auto; }
.expanded .detail-scroll { flex: 0 1 auto; }
.detail-map.inline { margin-top: 0.8em; aspect-ratio: 16 / 9; }
.eyebrow { margin: 0.8em 0 0; font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--accent); }
.detail-scroll h2 { margin: 0.2em 0 0.4em; font-size: 1.5em; font-weight: 800; line-height: 1.15; overflow-wrap: anywhere; }
.detail-head { display: grid; gap: 0.1em; }
.detail-pay { font-size: 1.8em; font-weight: 800; color: var(--money); line-height: 1.1; }
.detail-scroll small { display: block; color: var(--muted); font-size: 0.85em; }
.route-row { margin-top: 0.6em; display: grid; grid-template-columns: minmax(0, 1fr) auto minmax(0, 1fr); align-items: center; gap: 0.5em; padding: 0.6em 0.75em; border-radius: 0.5em; background: var(--panel); }
.route-cell { display: grid; gap: 0.1em; min-width: 0; }
.route-cell small { font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
.route-cell strong { line-height: 1.2; overflow-wrap: anywhere; }
.route-cell:last-child { text-align: right; justify-items: end; }
.route-arrow { display: grid; justify-items: center; gap: 0.15em; color: var(--accent); }
.route-arrow svg { width: 1.6em; height: 1.6em; fill: none; stroke: currentColor; stroke-width: 2.6; stroke-linecap: round; stroke-linejoin: round; }
.route-arrow em { font-style: normal; font-size: 0.72em; font-weight: 700; color: var(--faint); white-space: nowrap; }
.stop-copy { flex: 1 1 auto; }
.stop-photo { flex: 0 0 auto; width: 4.4em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35); }
.stop-photo img { display: block; width: 100%; height: 100%; object-fit: cover; }
.stop-dot { position: relative; z-index: 1; flex: 0 0 auto; width: 0.8em; height: 0.8em; margin: 0 0.35em; border-radius: 50%; background: var(--accent); border: 2px solid #1a1a1c; box-sizing: content-box; }
.stop-dot.end { background: #151517; border-color: #fff; }
.stop-copy { display: grid; gap: 0.05em; min-width: 0; }
.stop-copy small { font-size: 0.7em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
.stop-copy strong { font-size: 1.05em; line-height: 1.2; overflow-wrap: anywhere; }
.progress { margin-top: 1em; display: grid; gap: 0.4em; }
.progress .bar { display: flex; height: 0.55em; border-radius: 1em; overflow: hidden; background: rgba(255, 255, 255, 0.12); }
.progress .done { background: var(--ok); }
.progress .transit { background: var(--accent); }
.progress .legend { display: flex; justify-content: space-between; gap: 0.6em; font-size: 0.82em; color: var(--muted); }
.progress .legend b { color: #fff; }
.progress .legend span:nth-child(1) b { color: var(--ok); }
.progress .legend span:nth-child(2) b { color: #ffb27a; }
.detail-actions { padding: 0.75em 1em; border-top: 1px solid var(--line); display: flex; flex-wrap: wrap; gap: 0.4em; }
.next-step { flex-basis: 100%; display: flex; align-items: baseline; gap: 0.6em; min-width: 0; padding-bottom: 0.15em; }
.next-step .kicker { flex: 0 0 auto; }
.next-step-text { min-width: 0; font-size: 0.9em; font-weight: 600; color: rgba(255, 255, 255, 0.8); line-height: 1.25; }
.detail-actions button { flex: 1 1 40%; }
.detail-actions .primary { flex-basis: 100%; }
.reserve-amount { flex-basis: 100%; display: flex; align-items: center; gap: 0.7em; min-width: 0; }
.reserve-amount .kicker { flex: 0 0 auto; }
.reserve-note { display: inline-flex; align-items: center; gap: 0.5em; min-width: 0; color: var(--muted); font-size: 0.88em; font-weight: 600; white-space: nowrap; font-variant-numeric: tabular-nums; }
.reserve-note i { width: 0.22em; height: 0.22em; border-radius: 50%; background: var(--faint); }
.reserve-pay { margin-left: auto; color: var(--money); font-weight: 800; font-variant-numeric: tabular-nums; }
.detail-actions .count button { flex: 0 0 auto; }
.detail-actions small { flex-basis: 100%; color: var(--muted); font-size: 0.85em; }
.pickup-form { margin-top: 1em; display: grid; gap: 0.5em; }
.loader { margin-top: 1em; display: grid; gap: 0.6em; }
.loader .block-head .split-btn { margin-left: auto; font-size: 0.85em; }
.loader > .muted { margin: 0; font-size: 0.88em; line-height: 1.4; }
.load-veh { margin: -0.25em 0 0; color: var(--faint); font-size: 0.82em; }
.parcel-copy small > span + span::before { content: '·'; margin: 0 0.4em; }
.bins { list-style: none; margin: 0; padding: 0; display: grid; gap: 0.35em; }
.bin { display: grid; grid-template-columns: auto minmax(0, max-content) minmax(3em, 1fr) auto; grid-template-areas: "no copy bar left"; align-items: center; column-gap: 0.65em; padding: 0.5em 0.7em; border-radius: 0.5em; background: var(--panel); }
.bin .bin-no { grid-area: no; }
.bin-no { display: inline-grid; place-items: center; flex: 0 0 auto; width: 1.45em; height: 1.45em; padding-top: 0.12em; border-radius: 0.3em; background: var(--panel-2); color: rgba(255, 255, 255, 0.85); font-size: 0.78em; font-weight: 800; line-height: 1; font-variant-numeric: tabular-nums; }
.bin.planned .bin-no { background: rgba(255, 102, 0, 0.25); color: #ffb27a; }
.bin-copy { grid-area: copy; min-width: 0; display: flex; align-items: baseline; gap: 0.45em; }
.bin-copy strong { flex: 0 0 auto; font-size: 0.92em; line-height: 1.2; }
.bin-copy small { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--faint); font-size: 0.8em; }
.bin-left { grid-area: left; color: var(--faint); font-size: 0.8em; white-space: nowrap; font-variant-numeric: tabular-nums; }
.bin-left b { color: #fff; font-size: 1.1em; }
.bin-bar { grid-area: bar; display: flex; height: 0.4em; border-radius: 99em; overflow: hidden; background: rgba(0, 0, 0, 0.35); }
.bin-bar span { flex: 0 0 0; min-width: 0; }
.bin-bar .held { background: rgba(255, 255, 255, 0.28); }
.bin-bar .plan { background: var(--accent); }
.parcels { display: grid; gap: 0.35em; }
.parcel { display: grid; grid-template-columns: auto minmax(0, 1fr) auto; align-items: center; column-gap: 0.65em; row-gap: 0.4em; padding: 0.5em 0.5em 0.5em 0.55em; border-radius: 0.5em; background: var(--panel); transition: opacity 0.15s ease; }
.parcel.off { opacity: 0.5; }
.parcel .tick { flex: 0 0 auto; display: grid; place-items: center; width: 1.7em; height: 1.7em; padding: 0 !important; border-radius: 0.4em !important; background: var(--accent) !important; transition: background-color 0.12s ease; }
.parcel .tick svg { width: 1.1em; height: 1.1em; fill: none; stroke: #fff; stroke-width: 3; stroke-linecap: round; stroke-linejoin: round; transition: opacity 0.12s ease; }
.parcel.off .tick { background: transparent !important; box-shadow: inset 0 0 0 2px rgba(255, 255, 255, 0.35); }
.parcel.off .tick svg { opacity: 0; }
.parcel .tick:active { transform: scale(0.94); }
.parcel-copy { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.12em; }
.parcel-copy strong { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.92em; line-height: 1.2; }
.parcel-copy small { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--faint); font-size: 0.8em; font-variant-numeric: tabular-nums; }
.box-pick { flex: 0 1 auto; display: inline-flex; align-items: center; gap: 0.45em; min-width: 0; max-width: 55%; padding: 0.45em 0.6em 0.4em 0.45em !important; border-radius: 0.45em !important; background: var(--panel-2) !important; font-size: 0.85em; font-weight: 700; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; transition: background-color 0.12s ease; }
.box-pick .bin-no { background: rgba(255, 102, 0, 0.25); color: #ffb27a; font-size: 0.85em; }
.box-pick svg { flex: 0 0 auto; width: 0.95em; height: 0.95em; fill: none; stroke: var(--faint); stroke-width: 2.2; stroke-linecap: round; stroke-linejoin: round; transform: rotate(90deg); }
.broker .box-pick:disabled { opacity: 1; cursor: default; }
.box-pick:hover:not(:disabled) { background: rgba(255, 255, 255, 0.16) !important; }
.box-pick:active:not(:disabled) { transform: scale(0.97); }
.parcel.off .parcel-copy { opacity: 0.55; }
.parcel .tick.part { background: rgba(255, 102, 0, 0.45) !important; }
.parcel-copy .group-mult { margin-right: 0.3em; }
.count { display: inline-flex; font-size: 1.05em; align-items: center; border-radius: 0.45em; background: rgba(0, 0, 0, 0.3); font-variant-numeric: tabular-nums; }
.count button { width: 2.2em; height: 2.2em; padding: 0 !important; background: transparent !important; color: var(--muted); font-size: 1em; font-weight: 800; border-radius: 0.45em !important; }
.count button:hover:not(:disabled) { color: #fff; background: var(--panel-2) !important; }
.count button:disabled { opacity: 0.35; }
.count b { min-width: 1.5em; text-align: center; font-size: 1em; }
.splits { grid-column: 2 / -1; display: flex; flex-wrap: wrap; gap: 0.35em; }
.splits .box-pick { max-width: 100%; }
.box-pick em { font-style: normal; color: #ffb27a; font-variant-numeric: tabular-nums; }
.box-pick.nope { background: transparent !important; color: #ffb27a; box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.45); padding: 0.45em 0.6em 0.4em !important; cursor: default; }
.pickup-form .chips button { display: inline-flex; align-items: center; gap: 0.5em; }
.pickup-form .chips button .pill { font-size: 0.72em; }
.pickup-form label, .filter-page label { display: grid; gap: 0.4em; font-size: 0.85em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--faint); }
.pickup-form label input, .filter-page label :deep(*) { font-weight: 400; letter-spacing: 0; text-transform: none; }
.car-choices { margin-top: 1em; display: grid; gap: 0.45em; }
.car { position: relative; display: flex; align-items: center; gap: 0.7em; width: 100%; padding: 0.45em 0.7em 0.45em 0.45em !important; border: 0; border-radius: 0.5em !important; background: var(--panel) !important; color: inherit; font: inherit; font-weight: 400; text-align: left; white-space: normal; cursor: pointer; transition: background-color 0.18s ease, box-shadow 0.22s ease, transform 0.18s ease; }
.car:hover:not(:disabled) { background: var(--panel-2) !important; transform: translateY(-1px); }
.car:active:not(:disabled) { transform: translateY(0) scale(0.995); }
.car.picked { background: rgba(255, 102, 0, 0.07) !important; box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.45); animation: car-pick 0.28s ease-out; }
.car.picked:hover:not(:disabled) { background: rgba(255, 102, 0, 0.11) !important; }
.car.picked .car-copy strong { color: #fff; }
.car:disabled { cursor: default; opacity: 0.55; transform: none; }
.car.done .car-img img { filter: grayscale(0.8) brightness(0.6); }
.car:focus-visible { outline: none; box-shadow: 0 0 0 2px #fff, 0 0 0 4px rgba(255, 102, 0, 0.7); }
@keyframes car-pick { 0% { transform: scale(0.99); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.1); } 60% { transform: scale(1.004); box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.6); } 100% { transform: scale(1); } }
.car-img { position: relative; flex: 0 0 auto; width: 5.4em; aspect-ratio: 16 / 9; border-radius: 0.35em; overflow: hidden; background: rgba(0, 0, 0, 0.35); display: grid; place-items: center; color: rgba(255, 255, 255, 0.4); }
.car-img img { display: block; width: 100%; height: 100%; object-fit: cover; }
.car-state { position: absolute; top: 0.55em; right: 0.75em; font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
.car-state.ok { color: rgba(74, 222, 128, 0.75); }
.car-state.busy { color: #ffb27a; }
.car-copy { padding-right: 4.5em; }
.car-copy { flex: 1 1 auto; min-width: 0; display: grid; gap: 0.1em; }
.car-copy strong { line-height: 1.2; transition: color 0.18s ease; }
.car-copy small { color: var(--faint); font-size: 0.85em; }

/* ---- filters */
.filter-page { padding: 0.25em 1em 1em; display: flex; flex-direction: column; align-items: stretch; gap: 0.9em; }
.filter-page > .text-btn { align-self: flex-start; }
.filter-group h3 { margin: 0 0 0.5em; font-size: 0.85em; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: var(--faint); }
.filter-note { margin: 0.35em 0 0; font-size: 0.82em; font-weight: 600; color: var(--faint); line-height: 1.35; }
.market-chips { display: flex; flex-wrap: wrap; gap: 0.35em; }
.market-chips button { font-size: 0.78em; padding: 0.45em 0.65em 0.35em; }
.chips { display: flex; flex-wrap: wrap; gap: 0.4em; }
.chips button { background: var(--panel); padding: 0.5em 0.8em 0.4em; border-radius: 0.4em; }
.chips button.active { background: rgba(255, 102, 0, 0.25); color: #ffb27a; box-shadow: inset 0 0 0 1px rgba(255, 102, 0, 0.5); }
.filter-actions { display: flex; gap: 0.5em; margin-top: 0.5em; }
.filter-actions .primary { flex: 1; }
.broker-dropdown { width: 100%; min-width: 0; }

/* ---- route plan */
.route-plan { padding: 0 1em 1em; display: flex; flex-direction: column; gap: 0.7em; }
.route-plan > * { flex: 0 0 auto; }
.plan-map { aspect-ratio: 16 / 7; }
.route-summary { display: grid; gap: 0.6em; padding: 0.7em 0.8em; border-radius: 0.5em; background: var(--panel); }
.route-stats { display: flex; flex-wrap: wrap; gap: 0.4em 1.6em; }
.route-stats .stat { display: grid; gap: 0.1em; }
.stat-key { font-size: 0.68em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--faint); }
.stat-value { font-weight: 700; font-size: 1.1em; line-height: 1.2; }
.stat-value small { font-size: 0.75em; color: var(--faint); font-weight: 600; }
.route-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 0.4em; }
.route-actions .primary { display: inline-flex; align-items: center; gap: 0.4em; }
.stop-list { display: grid; gap: 0.4em; }
.plan-stop { position: relative; display: flex; gap: 0.6em; align-items: center; padding: 0.5em 0.6em; border-radius: 0.5em; background: var(--panel); }
.plan-index { flex: 0 0 auto; min-width: 1.9em; padding: 0.45em 0.45em 0.2em; display: grid; place-items: center; border-radius: 0.3em; background: rgba(255, 102, 0, 0.25); color: #ffb27a; font-size: 0.85em; font-weight: 700; line-height: 1; }
.plan-stop.delivery .plan-index { background: rgba(255, 255, 255, 0.1); color: rgba(255, 255, 255, 0.85); }
.stop-main { flex: 1; min-width: 0; text-align: left; background: none !important; padding: 0 !important; font-weight: 400; white-space: normal; display: grid; gap: 0.15em; justify-items: start; }
.stop-kind { margin-bottom: 0.1em; }
.stop-main strong { font-size: 1em; line-height: 1.2; }
.stop-main small { color: var(--muted); font-size: 0.85em; }
.leg { flex: 0 0 auto; display: grid; justify-items: end; gap: 0.15em; text-align: right; }
.leg-dist { font-weight: 700; font-variant-numeric: tabular-nums; }
.leg-status { font-size: 0.78em; color: var(--faint); }
.plan-move { display: flex; flex-direction: column; gap: 0.2em; }
.plan-move button { padding: 0.15em 0.35em; display: grid; place-items: center; }
.plan-move button :deep(.bng-icon) { font-size: 1.1em; }
.expanded .route-plan { width: 100%; max-width: 60em; margin: 0 auto; }
.expanded.filters-screen .apphead,
.expanded.filters-screen .filter-page {
  width: 100%;
  max-width: 60em;
  margin-left: auto;
  margin-right: auto;
  box-sizing: border-box;
}

/* ---- loaners */
.loaners { padding: 0 1em 1em; }
.loaners h3 { margin: 1em 0 0.5em; font-size: 0.75em; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; color: var(--accent); }
.depot-strip { padding: 0.7em 0.8em; border-radius: 0.5em; background: var(--panel); display: flex; justify-content: space-between; align-items: center; gap: 0.6em; flex-wrap: wrap; }
.loaner-card { padding: 0; border-radius: 0.5em; background: var(--panel); margin: 0 0 0.45em; display: flex; flex-direction: column; gap: 0.35em; overflow: hidden; }
.loaner-card > * { flex: 0 0 auto; }
.loaner-card > :not(.loaner-img) { margin-left: 0.8em; margin-right: 0.8em; }
.loaner-card > .card-top { margin-top: 0.6em; }
.loaner-card > .rental-actions { margin-bottom: 0.7em; }
.loaner-img { position: relative; aspect-ratio: 16 / 7; background: rgba(0, 0, 0, 0.35); }
.loaner-img img { display: block; width: 100%; height: 100%; object-fit: cover; }
.loaner-img::after { content: ""; position: absolute; inset: 0; background: linear-gradient(to top, rgba(20, 20, 22, 0.7), rgba(20, 20, 22, 0) 55%); pointer-events: none; }
.loaner-card p { margin: 0; color: var(--muted); font-size: 0.9em; }
.rental-actions { display: flex; gap: 0.4em; margin-top: 0.2em; }
.rental-actions button { flex: 1; }
.loaners > .muted { margin: 0.8em 0 0; font-size: 0.85em; line-height: 1.45; }

/* ---- toast */
.message { position: absolute; bottom: 4.4em; left: 1em; right: 1em; z-index: 10; text-align: left; padding: 0.75em 0.9em !important; background: #26262a !important; box-shadow: 0 10px 30px rgba(0, 0, 0, 0.6), inset 0 0 0 1px rgba(255, 102, 0, 0.5); font-weight: 400; white-space: normal; }
.message span { float: right; font-weight: 700; color: var(--accent); }

/* ---- expanded: full-screen board */
.expanded .apphead { padding: 0.6em 1.5em; }
.expanded .apphead h2 { font-size: 1.8em; }
.expanded .market-body { padding: 0 1.5em 1.5em; }
.expanded .market-grid { grid-template-columns: repeat(auto-fill, minmax(min(17em, 100%), 1fr)); gap: 0.6em; }
.expanded .market-tile { padding: 0.9em 1em !important; }
.expanded .toolbar { padding: 0 1.5em 0.6em; }
.expanded .load-list { padding: 0 1.5em 0.8em; }
.expanded .detail-scroll { padding: 0.75em 1.25em 1.25em; }
.expanded .loaners, .expanded .route-plan, .expanded .filter-page { padding-left: 1.5em; padding-right: 1.5em; }
.expanded .message { left: 25%; right: 25%; }
.expanded .nav { justify-content: center; gap: 2em; }
.expanded .jobs-tabs { justify-content: center; }
.expanded .jobs-tabs button { flex: 0 1 14em; }
.expanded .loaners { width: 100%; max-width: 70em; margin: 0 auto; }
.expanded .loaner-list { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(22em, 100%), 1fr)); gap: 0.6em; }
.expanded .loaner-card { margin: 0; }
.expanded .rental-actions button { flex: 0 1 auto; min-width: 7em; }
.expanded .nav button { flex: 0 1 9em; }

@media (min-width: 1100px) {
  .expanded .apphead, .expanded .toolbar, .expanded .workarea, .expanded .jobs-tabs { width: 100%; max-width: 100em; margin-left: auto; margin-right: auto; }
  .expanded .toolbar { grid-template-columns: minmax(16em, 1fr) auto; gap: 0.5em 0.8em; align-items: center; }
  .expanded .breadcrumb { grid-column: 1 / -1; margin: 0; }
  .expanded .toolbar input { margin: 0; }
  .expanded .toolbar-row .broker-dropdown { width: 14em; flex: none; }
  .expanded .workarea { display: grid; grid-template-columns: minmax(0, 7fr) minmax(20em, 3fr); grid-template-rows: minmax(0, 1fr); padding: 0 1.5em 1em; gap: 1em; }
  .expanded .load-list {
    padding: 0 0 0.6em;
    --broker-grid: 4.6em minmax(13em, 1.4fr) minmax(7em, 0.65fr) minmax(5.5em, 0.5fr) minmax(7em, 1fr) minmax(5.5em, 0.55fr);
  }
  .expanded .list-caption { margin: 0.2em 0.75em 0.6em; }
  .expanded .list-columns,
  .expanded .load-row {
    display: grid;
    grid-template-columns: var(--broker-grid);
    column-gap: 0.65em;
    align-items: center;
    padding-left: 0.75em;
    padding-right: 0.75em;
    box-sizing: border-box;
  }
  .expanded .list-columns {
    position: sticky;
    top: 0;
    z-index: 1;
    padding-top: 0.35em;
    padding-bottom: 0.4em;
    margin-bottom: 0.25em;
    background: linear-gradient(180deg, rgba(0, 0, 0, 0.35) 0%, rgba(0, 0, 0, 0.12) 100%);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
  }
  .expanded .col-head {
    display: flex;
    flex-direction: row;
    flex-wrap: nowrap;
    align-items: center;
    justify-content: flex-end;
    gap: 0.4em;
    min-width: 0;
    font-size: 0.72em;
    font-weight: 600;
    letter-spacing: 0.03em;
    text-transform: uppercase;
    color: rgba(255, 255, 255, 0.45);
  }
  .expanded .col-head.span-2 { grid-column: span 2; }
  .expanded .col-head.start { justify-content: flex-start; }
  .expanded .col-label {
    flex: 0 1 auto;
    min-width: 0;
    white-space: nowrap;
    line-height: 1.2;
  }
  .expanded .col-chevs {
    display: inline-flex;
    flex-direction: row;
    align-items: center;
    justify-content: center;
    flex: 0 0 auto;
    gap: 0.1em;
    padding: 0.15em 0.18em;
    border-radius: 0.35em;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.06);
    box-sizing: border-box;
  }
  .expanded .col-chevs .chev-btn {
    display: grid;
    place-items: center;
    width: 1.45em;
    height: 1.45em;
    padding: 0 !important;
    margin: 0;
    border-radius: 0.25em;
    background: transparent !important;
    color: rgba(255, 255, 255, 0.32);
    line-height: 1 !important;
    font-weight: 400;
    white-space: normal;
    transform: none;
  }
  .expanded .col-chevs .chev-btn svg {
    display: block;
    width: 0.95em;
    height: 0.95em;
    fill: none;
    stroke: currentColor;
    stroke-width: 2.4;
    stroke-linecap: round;
    stroke-linejoin: round;
  }
  .expanded .col-chevs .chev-btn:hover:not(:disabled) { color: rgba(255, 255, 255, 0.85) !important; background: rgba(255, 255, 255, 0.1) !important; transform: none; }
  .expanded .col-chevs .chev-btn.active { color: var(--accent) !important; background: rgba(255, 140, 0, 0.12) !important; }
  .expanded .load-row > .row-thumb { grid-column: 1; }
  .expanded .load-row > .row-summary { grid-column: 2; min-width: 0; }
  .expanded .wide-cell { display: block; min-width: 0; text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; }
  .expanded .cargo-cell { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .expanded .wide-cell.pay { color: var(--money); font-size: 1.05em; }
  .expanded .load-row .compact-pay, .expanded .load-row .row-bottom { display: none; }
  .expanded .detail-pane, .expanded .detail-placeholder { min-height: 0; border-radius: 0.6em; background: var(--panel); overflow: hidden; }
  .expanded .detail-placeholder { display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 2em; text-align: center; color: var(--muted); }
  .expanded .detail-placeholder :deep(.bng-icon) { font-size: 4em; color: rgba(255, 255, 255, 0.35); margin-bottom: 0.3em; }
  .expanded .detail-placeholder h3 { margin: 0 0 0.4em; color: #fff; font-size: 1.2em; }
  .expanded .detail-placeholder p { margin: 0 0 0.5em; max-width: 20em; }
  .expanded .detail-scroll h2 { font-size: 1.6em; }
  .expanded .detail-actions { background: rgba(0, 0, 0, 0.2); }
}
@media (max-width: 1099px) {
  .expanded .has-detail .load-list { display: none; }
  .expanded .message { left: 1em; right: 1em; }
}

/* ---- expanded market home: centred */
.expanded.market-home .apphead { width: 100%; max-width: 60em; margin: clamp(0.5em, 6vh, 4em) auto 0; padding: 0.6em 1.5em 0.4em; }
.expanded.market-home .apphead h2 { font-size: 2.2em; }
.expanded.market-home .market-body { width: 100%; max-width: 60em; margin: 0 auto; padding: 0 1.5em 1.5em; }
.expanded.market-home .intro { font-size: 1.05em; margin-bottom: 1em; }
.expanded.market-home .market-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 0.7em; }
.expanded.market-home .market-grid { grid-template-columns: repeat(3, minmax(0, 1fr)); }
.expanded.market-home .market-tile { flex-direction: column; align-items: stretch; padding: 0 !important; gap: 0; overflow: hidden; }
.expanded.market-home .market-tile .tile-img { width: 100%; aspect-ratio: 16 / 8; border-radius: 0; }
.expanded.market-home .market-tile .tile-glyph { left: 0.5em; bottom: 0.4em; font-size: 1.6em; }
.expanded.market-home .market-tile .tile-copy { padding: 0.6em 0.8em 0.2em; }
.expanded.market-home .market-tile .pill { margin: 0 0.8em 0.7em; }
.expanded.market-home .market-tile strong { font-size: 1.25em; }
.expanded.market-home .browse-all { margin-top: 0.9em; padding: 1em 1.1em !important; font-size: 1.05em; }
@media (max-width: 800px) { .expanded.market-home .market-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
</style>

<style lang="scss">
/* Job Broker dropdowns (unscoped: the option list is teleported to the popover container). */
.bng-dropdown.broker-dropdown {
  --bng-dropdown-bg: rgba(255, 255, 255, 0.1);
  --bng-dropdown-bg-hover: rgba(255, 255, 255, 0.16);
  --bng-dropdown-bg-active: rgba(255, 255, 255, 0.2);
  margin: 0;
  min-width: 0;
  padding: 0.55em 0.75em 0.45em 0.9em;
  border-radius: 0.6em;
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  font-weight: 700;
  color: #fff;
  &:focus::before { display: none; }
  &:focus-visible { box-shadow: 0 0 0 2px #fff, 0 0 0 4px rgba(255, 102, 0, 0.7); }
  & > .dropdown-arrow { order: 2; margin-left: auto; padding-left: 0.5em; font-size: 1.1em; color: var(--bng-orange-b400, #ff6600); }
  .dropdown-display { flex: 1 1 auto; min-width: 0; }
  .dropdown-display-label { font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
}
/* the popover shell around the list: no box of its own for broker dropdowns */
.bng-popover:has(> .bng-dropdown-content.broker-dropdown) {
  padding: 0;
  background: transparent;
  box-shadow: none;
  border: 0;
  > .bng-popover-arrow { display: none; }
}
.bng-dropdown-content.broker-dropdown {
  font-size: 0.85rem;
  background: #232326;
  border-radius: 0.6em;
  padding: 0.3em;
  box-shadow: 0 14px 34px rgba(0, 0, 0, 0.65), inset 0 0 0 1px rgba(255, 255, 255, 0.08);
  font-family: "Overpass", var(--fnt-defs, sans-serif);
  max-height: min(60vh, 24em);
  &::-webkit-scrollbar { width: 0.4em; }
  &::-webkit-scrollbar-track { background: transparent; }
  &::-webkit-scrollbar-thumb { background: rgba(255, 255, 255, 0.22); border-radius: 1em; border: 0.1em solid transparent; background-clip: padding-box; }
  &::-webkit-scrollbar-thumb:hover { background: rgba(255, 255, 255, 0.38); background-clip: padding-box; }
  .dropdown-option {
    --dropdown-option-hover-bg: rgba(255, 255, 255, 0.1);
    --dropdown-option-active-bg: rgba(255, 255, 255, 0.16);
    border-radius: 0.4em;
    padding: 0.6em 0.85em 0.45em;
    font-weight: 600;
    color: rgba(255, 255, 255, 0.85);
    &.selected { background-color: var(--bng-orange-b400, #ff6600) !important; color: #fff; }
  }
}
</style>
