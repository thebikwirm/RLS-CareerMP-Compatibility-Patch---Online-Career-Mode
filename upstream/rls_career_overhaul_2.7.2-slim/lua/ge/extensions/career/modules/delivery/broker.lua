-- Independent hauling facade. Native delivery modules own cargo and rewards.
local M = {}
local rules = require('gameplay/delivery/brokerRules')
local persistence = require('gameplay/delivery/brokerPersistence')
local pendingRestore = {cargo={},tasks={}}
local state = {version=1, jobs={}, plans={}, stops={}, rentals={}, depots={}, preferences={}, nextId=1}
local offers, natives, busy = {}, {}, false
local openContext
function M.setOpenContext(facility, atDepot, tab, select) openContext={facility=facility,depot=atDepot,tab=tab,select=select} end
local function gen() return career_modules_delivery_generator end
local function general() return career_modules_delivery_general end
local function parcels() return career_modules_delivery_parcelManager end
local function materials() return career_modules_delivery_materialContractManager end
local function vehicles() return career_modules_delivery_vehicleOfferManager end
local function ownerOp() return career_modules_delivery_ownerOpContracts end
local function mapId() return getCurrentLevelIdentifier() or '' end
local function now() return general().time() end
local function text(v) return _tr and _tr(v or '') or (v or '') end
local function employed()
  local e=career_modules_delivery_employment
  return e and e.isEmployed and e.isEmployed() or false
end
-- Drop-off adds a Logistics level bonus to parcel and vehicle pay (not to material contracts);
-- listings show pay with it so the figure matches what the player is paid.
local function levelBonus()
  local p=career_modules_delivery_progress
  if not (p and p.getLogisticsMoneyBonus) then return 0 end
  local ok,b=pcall(p.getLogisticsMoneyBonus)
  return ok and tonumber(b) or 0
end
local function withLevelPay(row,bonus)
  local applies=row.kind~='material' and row.kind~='cars'
  row.basePay=row.pay
  row.levelBonus=applies and bonus or 0
  row.estimatedPay=math.floor((tonumber(row.pay) or 0)*(1+row.levelBonus)+0.5)
  return row
end
-- Name of the current employer, for the "on the clock" screen in the phone app.
local function employerName()
  local e=career_modules_delivery_employment
  if not (e and e.isEmployed and e.isEmployed() and e.getUiState) then return nil end
  local ok,st=pcall(e.getUiState)
  return ok and type(st)=='table' and st.employerName or nil
end
local function nextId(prefix)
  local id=prefix..':'..tostring(state.nextId); state.nextId=state.nextId+1; return id
end
local function locationName(loc)
  local f=loc and gen().getFacilityById(loc.facId)
  return f and text(f.name) or (loc and loc.facId) or 'Destination'
end
local function position(loc)
  if not loc then return nil end
  local ok,pos=pcall(gen().getLocationCoordinates,loc)
  return ok and pos or nil
end
local function playerPosition()
  local v=getPlayerVehicle(0)
  return v and v:getPosition() or core_camera.getPosition()
end
local function near(loc)
  local pos=position(loc)
  return pos and (playerPosition()-pos):length()<30
end
local routeCache,routeCacheMap,routeCacheSize={},nil,0
local function distance(a,b,pickup)
  if not a or not b then return nil end
  if routeCacheMap~=mapId() or routeCacheSize>=8192 then
    routeCache={}; routeCacheMap=mapId(); routeCacheSize=0
  end
  -- Pickup estimates reuse routes within a 50 m grid cell; haul routes keep metre precision.
  local bucket=pickup and 50 or 1
  local key=string.format('%d:%d:%d:%d:%.0f:%.0f:%.0f',bucket,
    math.floor(a.x/bucket),math.floor(a.y/bucket),math.floor(a.z/bucket),b.x,b.y,b.z)
  if routeCache[key] then return routeCache[key] end
  local route=require('gameplay/route/route')()
  route:setupPath(a,b)
  local value=route.path and route.path[1] and route.path[1].distToTarget
  if value then routeCache[key]=value; routeCacheSize=routeCacheSize+1 end
  return value
end
local function destination(loc) return loc and deepcopy(loc) end
local function thousands(n) return (tostring(math.floor(n+0.5)):reverse():gsub('(%d%d%d)','%1,'):reverse():gsub('^,','')) end
local function materialTrips(c)
  local total,load=tonumber(c.totalAmount) or 0,tonumber(c.standardLoad) or 0
  if total<=0 or load<=0 then return nil end
  local perTrip=math.min(load,total); local trips=math.ceil(total/perTrip-1e-6)
  return string.format('%d trip%s of %s %s',trips,trips==1 and '' or 's',thousands(perTrip),c.units or 'L')
end
local function materialRequirement(c,materialType)
  local base=materialType=='cement' and 'Concrete mixer' or materialType=='cash' and 'Secure cargo capacity' or materialType=='fluid' and 'Liquid cargo capacity' or 'Bulk cargo capacity'
  local trips=materialTrips(c)
  return trips and (base..' · '..trips) or base
end
local function facilityPreview(loc)
  local g=gen()
  local fac=loc and loc.facId and g and g.getFacilityById and g.getFacilityById(loc.facId)
  return fac and fac.preview or nil
end
local function addOffer(id,kind,native,row)
  row.id=id; row.kind=kind; row.map=mapId()
  row.from=locationName(row.origin); row.to=locationName(row.destination)
  row.originPreview=facilityPreview(row.origin); row.destinationPreview=facilityPreview(row.destination)
  row.pickupDistance=distance(playerPosition(),position(row.origin),true)
  row.haulDistance=row.haulDistance or distance(position(row.origin),position(row.destination))
  row.pay=tonumber(row.pay) or 0
  row.signature=table.concat({row.map,kind,tostring(row.nativeId),row.from,row.to,tostring(row.title),tostring(row.quantity),tostring(row.pay),tostring(native.generatedAtTimestamp or '')},'|')
  offers[id]=row; natives[id]=native
end
local function findParcel(job)
  for _,c in ipairs(parcels().getAllCargoCustomFilter(function(c)
    return c.data and c.data.brokerId==job.id
  end) or {}) do return c end
end
local function syncJobs()
  for _,job in pairs(state.jobs) do
    if job.map==mapId() and job.status~='complete' and job.status~='cancelled' then
      if job.kind=='parcel' then
        local cargo=findParcel(job)
        if cargo and cargo.location and cargo.location.type=='vehicle' then job.status='active' end
        if cargo and cargo.location and cargo.location.type=='deleted' then job.status='cancelled' end
      elseif job.kind=='material' then
        local c=materials().getContractById(job.nativeId)
        if c then
          job.delivered=c.deliveredAmount or 0; job.remaining=c.remainingAmount
          job.inTransit=c.inTransitAmount or 0
          if job.delivered>0 or job.inTransit>0 then job.status='active' end
        elseif job.status=='active' then job.status='complete' end
      elseif job.kind=='trailer' then
        local o=vehicles().getOfferById(job.nativeId)
        if o and o.spawned then job.status='active' end
      elseif job.kind=='cars' then
        local c=ownerOp().getActiveContract()
        if c and c.id==job.nativeId then
          job.vehicles=deepcopy(c.vehicles or {})
          for _,v in ipairs(job.vehicles) do
            local offer=v.offerId and vehicles().getOfferById(v.offerId)
            if offer and offer.vehicle and not v.thumbnail then
              local m=core_vehicles.getModel(offer.vehicle.model)
              local cfg=m and m.configs and offer.vehicle.config and m.configs[offer.vehicle.config]
              v.thumbnail=cfg and cfg.preview or nil
            end
            if v.status=='delivered' or (offer and offer.spawned) then job.status='active' end
          end
        elseif job.status=='active' then job.status='complete' end
      end
    end
  end
end
local function booked(kind,id)
  for _,j in pairs(state.jobs) do
    if j.map==mapId() and j.kind==kind and j.nativeId==id and j.status~='cancelled' and j.status~='complete' then return true end
  end
  return false
end
M.isNativeBooked=booked
function M.jobForNative(kind,id)
  for key,j in pairs(state.jobs) do
    if j.kind==kind and j.nativeId==id and j.map==mapId() and j.status~='complete' and j.status~='cancelled' then return key end
  end
end
function M.refreshOffers()
  offers={}; natives={}
  -- After an in-career map switch the generator may still hold the previous map's
  -- facilities; re-run delivery setup (no-op when already set up for this map).
  local g=general()
  if g and g.ensureSetupForCurrentMap then g.ensureSetupForCurrentMap() end
  if gen().getSetupLevelIdentifier and gen().getSetupLevelIdentifier()~=mapId() then return end
  gen().triggerAllGenerators()
  for _,fac in ipairs(gen().getFacilities() or {}) do
    for _,c in ipairs(parcels().getAllCargoForFacilityUnexpiredUndelivered(fac.id) or {}) do
      if c.type=='parcel' and not (c.data and c.data.brokerId) then
        gen().finalizeParcelItemDistanceAndRewards(c)
        local keys={}; for _,modifier in ipairs(c.modifiers or {}) do keys[modifier.type]=true end
        local locked=career_modules_delivery_parcelMods.lockedBecauseOfMods(keys)
        local unlocked=not locked; local reason=locked and 'Logistics level required' or nil
        addOffer('parcel:'..c.id,'parcel',c,{nativeId=c.id,market='parcels',title=text(c.name),origin=destination(c.origin),destination=destination(c.destination),pay=c.rewards.money,quantity=c.slots,unit='slots',weight=c.weight,requirement='Cargo space',arrangement='own',unlocked=unlocked,lockedReason=reason})
      end
    end
    for _,c in ipairs(materials().getOffersForFacility(fac.id) or {}) do
      local material=gen().getMaterialsTemplatesById(c.materialType)
      if material and not booked('material',c.id) then
        addOffer('material:'..c.id,'material',c,{nativeId=c.id,market=rules.materialMarket(material.type),subtype=material.type,title=text(material.name),origin=destination(c.origin),destination=destination(c.destination),pay=c.quotedRewards.money,quantity=c.totalAmount,unit=c.units or 'L',haulDistance=c.routeDistance,requirement=materialRequirement(c,material.type),arrangement='own',unlocked=true})
      end
    end
    for _,o in ipairs(vehicles().getAllOfferAtFacilityUnexpired(fac.id) or {}) do
      if o.data and o.data.type=='trailer' and not booked('trailer',o.id) then
        gen().finalizeVehicleOffer(o)
        local tag=o.vehicle and (o.vehicle.unlockTag or o.vehicle.filterId) or ''
        local unlocked=vehicles().isVehicleTagUnlocked(tag)
        addOffer('trailer:'..o.id,'trailer',o,{nativeId=o.id,market='trailers',title=text(o.vehicle and (o.vehicle.filterName or o.vehicle.name) or 'Trailer load'),origin=destination(o.origin),destination=destination(o.task.destination),pay=o.rewards and o.rewards.money,trailerType=vehicles().getVehicleTagLabelSingular(tag),quantity=1,unit='trailer',requirement='Compatible tow vehicle',arrangement='supplied',unlocked=unlocked~=false})
      end
    end
  end
  for _,c in ipairs(ownerOp().listContracts() or {}) do
    if c.kind=='finkHaul' and not booked('cars',c.id) then
      local native=ownerOp().getBrokerOffer(c.id)
      if native then
        local fac=gen().getFacilityById(c.originFacId)
        local ps=fac and (fac.pickUpSpots[1] or fac.inspectSpots[1])
        local first=native.vehicles and native.vehicles[1]
        local dest=first and {type='facilityParkingspot',facId=first.destFacId,psPath=first.destPsPath}
        addOffer('cars:'..c.id,'cars',native,{nativeId=c.id,market='cars',title=c.title,origin={type='facilityParkingspot',facId=c.originFacId,psPath=ps and ps:getPath()},destination=dest,pay=c.pay,quantity=#(native.vehicles or {}),unit='vehicles',vehicles=deepcopy(c.vehicles),requirement='Car transport equipment',arrangement='own',unlocked=ownerOp().isOwnerOpUnlocked(),destinations=c.destinations})
      end
    end
  end
end
local function refreshPois()
  if general().requestDeliveryPoiRefresh then general().requestDeliveryPoiRefresh(true) end
end
function M.reserve(id,signature,keepOffers)
  if busy then return false,'Finish the current collection first.' end
  if employed() then return false,'Job Broker is for independent contractors.' end
  syncJobs()
  if not keepOffers then M.refreshOffers() end
  local plan=state.plans[id]
  if plan then signature=plan.signature; id=plan.offerId end
  local row,native=offers[id],natives[id]
  if not row or row.unlocked==false then return false,'This load is no longer available or requires a higher level.' end
  if signature and signature~=row.signature then return false,'This saved offer has changed. Choose a current load from the market.' end
  local job=deepcopy(row); job.id=nextId('job'); job.offerId=id; job.status='reserved'
  if row.kind=='material' then
    if not materials().acceptBrokerContract(row.nativeId) then return false,'This contract is no longer available.' end
  elseif row.kind=='parcel' then
    native.data=native.data or {}; native.data.brokerId=job.id
    job.originalExpiry=native.offerExpiresAt; native.offerExpiresAt=1e30
  elseif row.kind=='trailer' then
    job.originalExpiry=native.offerExpiresAt; native.offerExpiresAt=1e30; native.brokerId=job.id
  elseif row.kind=='cars' then job.native=deepcopy(native) end
  state.jobs[job.id]=job
  for key,p in pairs(state.plans) do
    if key==id or (p.offerId==id and p.signature==row.signature) then
      for _,stop in ipairs(state.stops) do if stop.jobId==key then stop.jobId=job.id end end
      state.plans[key]=nil
    end
  end
  refreshPois()
  return true,'Load reserved.',job.id
end
function M.cancel(id)
  if busy then return false,'Finish the current collection first.' end
  syncJobs()
  local job=state.jobs[id]
  if not job or job.map~=mapId() or job.status~='reserved' then return false,'Only uncollected reservations can be cancelled here.' end
  if job.kind=='cars' and not ownerOp().cancelUnstartedBrokerContract(job.nativeId) then return false,'Vehicle collection has already begun.' end
  if job.kind=='material' then materials().abandonContract(job.nativeId,{noFine=true,silent=true})
  elseif job.kind=='parcel' then
    local c=findParcel(job); if c then c.data.brokerId=nil; c.offerExpiresAt=math.max(now()+60,job.originalExpiry or 0) end
  elseif job.kind=='trailer' then
    local o=vehicles().getOfferById(job.nativeId); if o then o.brokerId=nil; o.offerExpiresAt=math.max(now()+60,job.originalExpiry or 0) end
  end
  state.jobs[id]=nil
  for i=#state.stops,1,-1 do if state.stops[i].jobId==id then table.remove(state.stops,i) end end
  refreshPois(); return true,'Reservation cancelled.'
end
local function cancelReservationForTravel(id)
  syncJobs()
  local job=state.jobs[id]
  if not job or job.status~='reserved' then return false,'Only uncollected reservations can be cancelled.' end
  if job.kind=='cars' and not ownerOp().cancelUnstartedBrokerContract(job.nativeId) then return false,'Vehicle collection has already begun.' end
  if job.kind=='material' then materials().abandonContract(job.nativeId,{noFine=true,silent=true})
  elseif job.kind=='parcel' then
    local c=findParcel(job); if c then c.data.brokerId=nil; c.offerExpiresAt=math.max(now()+60,job.originalExpiry or 0) end
  elseif job.kind=='trailer' then
    local o=vehicles().getOfferById(job.nativeId); if o then o.brokerId=nil; o.offerExpiresAt=math.max(now()+60,job.originalExpiry or 0) end
  end
  state.jobs[id]=nil
  for i=#state.stops,1,-1 do if state.stops[i].jobId==id then table.remove(state.stops,i) end end
  refreshPois()
  return true
end
function M.navigate(id,leg,stopId)
  local item=state.jobs[id] or offers[id] or state.plans[id]
  if not item or item.map~=mapId() then return false,'This load is on another map.' end
  local loc=leg=='delivery' and item.destination or item.origin
  if stopId then for _,stop in ipairs(state.stops) do if stop.id==stopId and stop.jobId==id then loc=stop.location or loc; break end end end
  local pos=position(loc)
  if not pos then return false,'The selected stop is unavailable.' end
  general().setDeliveryNavFocus(pos)
  core_groundMarkers.setPath({pos},{clearPathOnReachingTarget=false})
  return true,leg=='delivery' and 'Route to delivery set.' or 'Route to pickup set.'
end
function M.plan(id)
  for key,p in pairs(state.plans) do if p.offerId==id then id=key; break end end
  if state.plans[id] then
    state.plans[id]=nil
    for i=#state.stops,1,-1 do if state.stops[i].jobId==id then table.remove(state.stops,i) end end
    return true,'Plan removed.'
  end
  local row=offers[id] or state.jobs[id]
  if not row then return false,'This load is no longer available.' end
  local originalId=id
  if not row.status then id=nextId('plan') end
  state.plans[id]=deepcopy(row); state.plans[id].id=id; state.plans[id].offerId=originalId
  state.stops[#state.stops+1]={id=nextId('stop'),jobId=id,kind='pickup',location=deepcopy(row.origin),name=row.from}
  local destinations={row.destination}
  if row.kind=='cars' then
    destinations={}; local seen={}
    for _,car in ipairs(row.vehicles or {}) do
      local key=tostring(car.destFacId)..':'..tostring(car.destPsPath)
      if not seen[key] then destinations[#destinations+1]={type='facilityParkingspot',facId=car.destFacId,psPath=car.destPsPath}; seen[key]=true end
    end
    if not destinations[1] then destinations={row.destination} end
  end
  for _,loc in ipairs(destinations) do state.stops[#state.stops+1]={id=nextId('stop'),jobId=id,kind='delivery',location=deepcopy(loc),name=locationName(loc)} end
  return true,'Added to route.'
end
function M.moveStop(index,delta)
  index=tonumber(index); delta=tonumber(delta)
  if not index or (delta~=-1 and delta~=1) or not state.stops[index] or not state.stops[index+delta] then return false,'Cannot move this stop.' end
  local copy=deepcopy(state.stops); copy[index],copy[index+delta]=copy[index+delta],copy[index]
  if not rules.validStopOrder(copy) then return false,'Delivery must follow pickup.' end
  state.stops=copy; return true,'Route updated.'
end
-- ---- route planning: the saved stops become one ground-marker path, with road distances per leg
local function stopPoints()
  local pts={}
  for _,stop in ipairs(state.stops) do
    local pos=position(stop.location)
    if pos then pts[#pts+1]={stop=stop,pos=pos} end
  end
  return pts
end
function M.routeSummary()
  local legs,total,prev={},0,playerPosition()
  for _,p in ipairs(stopPoints()) do
    local d=distance(prev,p.pos)
    legs[#legs+1]={stopId=p.stop.id,distance=d}
    if d then total=total+d end
    prev=p.pos
  end
  return {legs=legs,total=total,stops=#legs}
end
function M.showRoute()
  local pts=stopPoints()
  if not pts[1] then return false,'Save loads to your route first.' end
  local list={}
  for _,p in ipairs(pts) do list[#list+1]=p.pos end
  general().setDeliveryNavFocus(list[1])
  core_groundMarkers.setPath(list,{clearPathOnReachingTarget=false})
  return true,string.format('Route set through %d stop%s.',#list,#list==1 and '' or 's')
end
function M.clearRoute()
  core_groundMarkers.setPath(nil)
  return true,'Route cleared.'
end
function M.optimizeStops()
  if #state.stops<2 then return false,'Add more stops to order them.' end
  local remaining,ordered,cur=deepcopy(state.stops),{},playerPosition()
  while #remaining>0 do
    local bestI,bestD
    for i,stop in ipairs(remaining) do
      local blocked=false
      if stop.kind=='delivery' then
        for _,o in ipairs(remaining) do if o~=stop and o.jobId==stop.jobId and o.kind=='pickup' then blocked=true break end end
      end
      if not blocked then
        local pos=position(stop.location)
        local d=pos and distance(cur,pos) or math.huge
        if not bestD or d<bestD then bestI,bestD=i,d end
      end
    end
    if not bestI then break end
    local stop=table.remove(remaining,bestI)
    ordered[#ordered+1]=stop; cur=position(stop.location) or cur
  end
  for _,stop in ipairs(remaining) do ordered[#ordered+1]=stop end
  if not rules.validStopOrder(ordered) then return false,'Could not order the stops.' end
  state.stops=ordered
  return true,'Stops ordered by shortest drive.'
end
-- polyline along the roads between two points, for the phone's route map
local function routePolyline(a,b)
  local route=require('gameplay/route/route')()
  route:setupPath(a,b)
  local path={}
  for _,p in ipairs(route.path or {}) do path[#path+1]={p.pos.x,p.pos.y} end
  local total=route.path and route.path[1] and route.path[1].distToTarget or nil
  if #path<2 then path={{a.x,a.y},{b.x,b.y}} end
  return path,total
end
function M.routePreview(id)
  local item=state.jobs[id] or offers[id] or state.plans[id]
  if not item or item.map~=mapId() then return nil end
  local a,b=position(item.origin),position(item.destination)
  if not a or not b then return nil end
  local me=playerPosition()
  local p1,d1=routePolyline(me,a)
  local p2,d2=routePolyline(a,b)
  return {legs={{kind='approach',path=p1,distance=d1},{kind='delivery',path=p2,distance=d2}},
    points={player={me.x,me.y},pickup={a.x,a.y},delivery={b.x,b.y}}}
end
function M.planPreview()
  local pts=stopPoints()
  if not pts[1] then return nil end
  local prev=playerPosition()
  local legs,stops={},{}
  for _,p in ipairs(pts) do
    local path,d=routePolyline(prev,p.pos)
    legs[#legs+1]={stopId=p.stop.id,kind=p.stop.kind=='pickup' and 'pickup' or 'delivery',path=path,distance=d}
    stops[#stops+1]={p.pos.x,p.pos.y,p.stop.kind}
    prev=p.pos
  end
  local me=playerPosition()
  return {legs=legs,points={player={me.x,me.y},stops=stops}}
end
function M.setPreferences(value)
  if type(value)=='table' then state.preferences=deepcopy(value) end
end
function M.onBrokerCargoDelivered(cargoItems)
  for _,c in ipairs(cargoItems or {}) do
    local id=c.data and c.data.brokerId
    if id and state.jobs[id] and state.jobs[id].kind=='parcel' then state.jobs[id].status='complete' end
  end
end
function M.onBrokerVehicleDelivered(items)
  for _,o in ipairs(items or {}) do
    o=o.offer or o
    if o.brokerId and state.jobs[o.brokerId] and state.jobs[o.brokerId].kind=='trailer' then state.jobs[o.brokerId].status='complete' end
  end
end
function M.serialize()
  syncJobs()
  local saved=deepcopy(state)
  saved.inTransit=persistence.capture(pendingRestore)
  return saved
end
function M.onBrokerVehicleAbandoned(offer)
  local job=offer and state.jobs[offer.brokerId]
  if job and job.kind=='trailer' then job.status='cancelled' end
end
function M.setup(saved)
  local tasks=career_modules_delivery_vehicleTasks
  if tasks and tasks.clearBrokerTasksForLoad then tasks.clearBrokerTasksForLoad() end
  state={version=1,jobs={},plans={},stops={},rentals={},depots={},preferences={},nextId=1}
  if type(saved)=='table' then for k,v in pairs(saved) do state[k]=v end end
  offers={}; natives={}; busy=false
  pendingRestore=state.inTransit or {cargo={},tasks={}}; state.inTransit=nil
  if vehicles() and vehicles().getAllOfferCustomFilter then
    for _,offer in ipairs(vehicles().getAllOfferCustomFilter(function(o) return o.brokerId ~= nil end) or {}) do
      local job=state.jobs[offer.brokerId]
      if job and job.kind=='trailer' then job.nativeId=offer.id end
    end
  end
  persistence.prepare(pendingRestore,state.jobs)
end
local restoreTimer=0
function M.onUpdate(dtReal)
  if not career_career or not career_career.isActive() then return end
  restoreTimer=restoreTimer+(dtReal or 0)
  if restoreTimer<1 then return end
  restoreTimer=0
  if next(pendingRestore.cargo or {}) or next(pendingRestore.tasks or {}) then persistence.restore(pendingRestore,state.jobs) end
end
function M.getState()
  syncJobs(); M.refreshOffers()
  local bonus=levelBonus()
  local list={}; for _,r in pairs(offers) do
    r.atPickup=r.kind=='parcel' and r.map==mapId() and near(r.origin) or nil
    list[#list+1]=withLevelPay(r,bonus)
  end
  local jobs={}; for _,j in pairs(state.jobs) do
    local row=deepcopy(j); row.native=nil; row.atPickup=row.map==mapId() and near(row.origin) or false
    row.atDelivery=row.map==mapId() and near(row.destination) or false
    withLevelPay(row,bonus)
    if row.status=='active' and row.map==mapId() then row.abandonFine=M.abandonQuote(row.id) end
    jobs[#jobs+1]=row
  end
  local context=openContext; openContext=nil
  return {markets=rules.markets,offers=list,jobs=jobs,plans=state.plans,stops=state.stops,preferences=state.preferences,openContext=context,
    reservationCount=rules.holdCount(state.jobs),employed=employed(),employerName=employerName(),map=mapId(),busy=busy,
    profile=career_saveSystem and career_saveSystem.getCurrentSaveSlot and career_saveSystem.getCurrentSaveSlot() or '',
    depot=M.getDepotView and M.getDepotView(),loaners=M.getLoanerCatalog and M.getLoanerCatalog() or {},rentals=M.getRentals and M.getRentals() or {},
    route=M.routeSummary()}
end
function M.abandonQuote(id)
  local job=state.jobs[id]
  if not job then return 0 end
  if job.kind=='material' then
    local c=materials().getContractById(job.nativeId)
    return c and c.abandonmentFine or 0
  elseif job.kind=='parcel' then
    local fine=general().getDeliveryModePenalty(nil,false,function(c) return c.data and c.data.brokerId==id end)
    return -(fine.money or 0)
  end
  local fine=0
  for _,task in ipairs(career_modules_delivery_vehicleTasks.getVehicleTasks()) do
    if task.offer.brokerId==id and not task.remove then fine=fine-(career_modules_delivery_vehicleTasks.getFineForAbandon(task).money or 0) end
  end
  return fine
end
function M.abandon(id)
  local job=state.jobs[id]
  if busy or not job or job.status~='active' or job.map~=mapId() then return false,'Select work in progress on this map.' end
  for _,saved in pairs(pendingRestore.cargo or {}) do if saved.cargo.data.brokerId==id then return false,'Wait for the loaded vehicle to restore first.' end end
  for _,saved in pairs(pendingRestore.tasks or {}) do if saved.offer.brokerId==id then return false,'Wait for the delivery vehicle to restore first.' end end
  if job.kind=='material' then materials().abandonContract(job.nativeId)
  elseif job.kind=='cars' then if not ownerOp().abandonBrokerContract(job.nativeId) then return false,'This contract is unavailable.' end
  elseif job.kind=='trailer' then
    local offer=vehicles().getOfferById(job.nativeId)
    if not offer or not offer.vehicle.vehId then return false,'The trailer is unavailable.' end
    career_modules_delivery_vehicleTasks.giveBackDeliveryVehicle(offer.vehicle.vehId)
  else
    local fine=general().getDeliveryModePenalty(nil,false,function(c) return c.data and c.data.brokerId==id end)
    for _,c in ipairs(parcels().getAllCargoCustomFilter(function(c) return c.data and c.data.brokerId==id end)) do parcels().changeCargoLocation(c.id,{type='deleted'}) end
    career_modules_playerAttributes.addAttributes(fine,{tags={'gameplay','delivery','fine'},label='Cargo abandonment'})
    general().requestUpdateContainerWeights()
  end
  job.status='cancelled'; refreshPois(); career_modules_delivery_tasklist.sendCargoToTasklist()
  return true,'Work abandoned. Existing delivery penalties apply.'
end
-- A "3×" group in My Loads is several identical jobs; abandon or cancel them together.
-- Each job goes through the normal single-job path, so fines and cleanup are unchanged.
local function eachJob(ids,fn)
  local done,reason=0,nil
  for _,id in ipairs(type(ids)=='table' and ids or {}) do
    local ok,msg=fn(id)
    if ok then done=done+1 else reason=reason or msg end
  end
  return done,reason
end
function M.abandonMany(ids)
  local done,reason=eachJob(ids,M.abandon)
  if done==0 then return false,reason or 'Select work in progress on this map.' end
  local head=done==1 and 'Work abandoned.' or done..' loads abandoned.'
  return true,reason and head..' Some could not be abandoned: '..reason or head..' Existing delivery penalties apply.'
end
function M.cancelMany(ids)
  local done,reason=eachJob(ids,M.cancel)
  if done==0 then return false,reason or 'Only uncollected reservations can be cancelled here.' end
  local head=done==1 and 'Reservation cancelled.' or done..' reservations cancelled.'
  return true,reason and head..' Some could not be cancelled: '..reason or head
end
local function inventoryRental(id)
  for invId,v in pairs(career_modules_inventory.getVehicles() or {}) do
    if v.brokerRentalId==id then return invId,v end
  end
end
local function reconcileRentals()
  for id,r in pairs(state.rentals) do
    local invId=inventoryRental(id)
    if invId then r.status='rented'; r.inventoryId=invId
    elseif r.status=='rented' then state.rentals[id]=nil end
  end
end
local function openJob(j) return j.status~='complete' and j.status~='cancelled' end
function M.hasObligations()
  syncJobs(); reconcileRentals()
  for _,j in pairs(state.jobs) do if openJob(j) then return true end end
  for _,r in pairs(state.rentals) do if r.status~='returned' then return true end end
  return false
end
function M.getObligations()
  syncJobs(); reconcileRentals()
  local jobs,rentals,fine={},{},0
  for _,j in pairs(state.jobs) do
    if openJob(j) then
      local row={id=j.id,kind=j.kind,title=j.title,from=j.from,to=j.to,status=j.status,map=j.map,onMap=j.map==mapId(),fine=0}
      if j.status=='active' and row.onMap then row.fine=M.abandonQuote(j.id) end
      fine=fine+row.fine
      jobs[#jobs+1]=row
    end
  end
  for id,r in pairs(state.rentals) do
    if r.status~='returned' then
      rentals[#rentals+1]={id=id,name=r.name,status=r.status,map=r.map,onMap=r.map==mapId(),collected=inventoryRental(id)~=nil}
    end
  end
  table.sort(jobs,function(a,b)return a.id<b.id end)
  table.sort(rentals,function(a,b)return a.id<b.id end)
  return {jobs=jobs,rentals=rentals,totalFine=fine,count=#jobs+#rentals}
end
function M.clearObligations(callback)
  if busy then return false,'Finish the current collection first.' end
  syncJobs(); reconcileRentals()
  local failures={}
  local function fail(label,message) failures[#failures+1]=tostring(label or '?')..': '..tostring(message or 'failed') end
  local jobIds={}
  for id in pairs(state.jobs) do jobIds[#jobIds+1]=id end
  table.sort(jobIds)
  for _,id in ipairs(jobIds) do
    local j=state.jobs[id]
    if j and j.status=='reserved' then
      local ok,msg=cancelReservationForTravel(id)
      if not ok then fail(j.title or id,msg) end
    elseif j and j.status=='active' then
      local ok,msg=M.abandon(id)
      if not ok then fail(j.title or id,msg) end
    end
  end
  local toReturn={}
  for id,r in pairs(state.rentals) do
    local invId=inventoryRental(id)
    if invId then toReturn[#toReturn+1]={id=id,name=r.name,invId=invId}
    elseif r.status~='returned' then state.rentals[id]=nil end
  end
  local pending=#toReturn
  local function finish()
    if pending>0 then return end
    busy=false; reconcileRentals(); refreshPois()
    if callback then callback(#failures==0,failures) end
  end
  if pending==0 then finish(); return true end
  busy=true
  local loaners=career_modules_loanerVehicles
  if loaners.stepOutIfInCompanyVehicle then loaners.stepOutIfInCompanyVehicle() end
  for _,item in ipairs(toReturn) do
    loaners.returnVehicle(item.invId,function(ok)
      pending=pending-1
      if ok==false or inventoryRental(item.id) then fail(item.name or item.id,'could not be returned.')
      else state.rentals[item.id]=nil end
      finish()
    end)
  end
  return true
end
-- Collection and depot operations are installed below; shared upvalues keep transactions serialized.

function M.pickup(id,amount,containerKey,selectedCars,callback)
  local function finish(ok,message)
    busy=false; syncJobs(); refreshPois()
    if callback then callback(ok,message) end
  end
  if busy or employed() then return false,'Collection is unavailable right now.' end
  local job=state.jobs[id]
  if not job or job.map~=mapId() or (job.status~='reserved' and job.status~='active') then return false,'Select a current reservation.' end
  if not near(job.origin) then return false,'Drive to the marked pickup first.' end
  if job.kind=='trailer' then
    if job.status~='reserved' then return false,'This trailer has already been collected.' end
    busy=true
    vehicles().spawnOffer(job.nativeId,true,function(ok)
      local offer=vehicles().getOfferById(job.nativeId)
      if offer and offer.spawned then job.status='active'; finish(true,'Trailer ready for collection.')
      else finish(false,'The trailer could not be placed. Clear the pickup bay and retry.') end
    end)
    return true,'Collecting trailer…'
  elseif job.kind=='cars' then
    local active=ownerOp().getActiveContract()
    if not active or active.id~=job.nativeId then
      local ok,msg=ownerOp().startBrokerContract(job.native)
      if not ok then return false,msg end
    end
    local ok,msg=ownerOp().stageCarHaulTrip(selectedCars or {})
    syncJobs(); return ok,msg
  end
  busy=true
  general().getNearbyVehicleCargoContainers(function(containers)
    if not near(job.origin) or employed() then finish(false,'Return to the pickup to load.'); return end
    local target
    for _,con in ipairs(containers or {}) do
      if tostring(con.vehId)..':'..tostring(con.containerId)==containerKey then target=con; break end
    end
    if not target then finish(false,'Select a nearby cargo container, then retry.'); return end
    if job.kind=='parcel' then
      local c=findParcel(job)
      if not c or c.location.type~='facilityParkingspot' or c.location.facId~=job.origin.facId then finish(false,'This cargo has already moved.'); return end
      if not target.cargoTypesLookup.parcel or target.freeCargoSlots<c.slots then finish(false,'This container needs more compatible cargo space.'); return end
      local emp=career_modules_delivery_employment
      if emp and emp.canMoveCargoOntoLocation and not emp.canMoveCargoOntoLocation(c.id,target.location) then finish(false,'This vehicle cannot accept independent cargo.'); return end
      if #(parcels().getTransientMoveCargo() or {})>0 then finish(false,'Finish the existing loading operation first.'); return end
      career_modules_delivery_cargoScreen.moveCargoFromUi(c.id,target.location)
      career_modules_delivery_cargoScreen.commitDeliveryConfiguration(function()
        local moved=findParcel(job)
        finish(moved and moved.location.type=='vehicle',moved and moved.location.type=='vehicle' and 'Cargo loaded.' or 'Cargo could not be loaded. Retry at the pickup.')
      end)
    elseif job.kind=='material' then
      local c=materials().getContractById(job.nativeId)
      local mat=c and gen().getMaterialsTemplatesById(c.materialType)
      local fac=c and gen().getFacilityById(c.sourceFacId)
      local storage=fac and fac.materialStorages[c.materialType]
      local value=tonumber(amount)
      if not value or value~=value or value<=0 or value==math.huge then finish(false,'Enter a positive quantity.'); return end
      if not c or not mat or not storage or not target.cargoTypesLookup[mat.type] then finish(false,'Choose compatible cargo capacity.'); return end
      if target.rawCargo[1] and target.rawCargo[1].materialType~=c.materialType then finish(false,'Empty the other material first.'); return end
      if value>math.min(c.loadableAmount or 0,target.freeCargoSlots or 0) then finish(false,'Requested quantity exceeds free capacity or the remaining order.'); return end
      local ok=gen().addMaterialAsParcelToContainer(target,storage,value,c.sourceFacId,c.origin.psPath,c.id)
      if ok then
        parcels().applyTransientMoves(c.origin)
        for _,cargo in ipairs(parcels().getAllCargoInVehicles() or {}) do
          if cargo.data and cargo.data.materialContractId==job.nativeId then cargo.data.brokerId=job.id end
        end
        if not general().isDeliveryModeActive() then general().startDeliveryMode() end
        general().requestUpdateContainerWeights()
        career_modules_delivery_tasklist.sendCargoToTasklist()
        materials().refreshTaskGuidance(true)
        job.status='active'
      end
      finish(ok,ok and 'Material loaded.' or 'Unable to load this quantity.')
    else finish(false,'Unsupported pickup.') end
  end)
  return true,'Checking cargo capacity…'
end
-- Loads several reserved parcels at one pickup in a single cargo commit. items: {{id=jobId,container='vehId:containerId'},...}
-- Every parcel is checked against the space left in its box after the parcels before it, so a split never overfills.
-- Reserved parcels still waiting at their pickup spot. general.lua turns these into the vanilla
-- "Pick Up" prompt on that parking spot, which opens the Job Broker loader for them.
function M.getReservedPickups()
  local out={}
  if employed() then return out end
  for _,job in pairs(state.jobs) do
    local o=job.origin
    if job.kind=='parcel' and job.status=='reserved' and job.map==mapId() and o and o.psPath then
      out[#out+1]={facId=o.facId,psPath=o.psPath,jobId=job.id,title=job.title,slots=tonumber(job.quantity) or 0}
    end
  end
  return out
end
-- Reserves several identical offers (a "3×" group) in one go. items: {{id=offerId,signature=...},...}
-- Offers are refreshed once up front; stops at the first offer that can no longer be reserved and reports how many were taken.
function M.reserveMany(items)
  local list={}
  for _,item in ipairs(type(items)=='table' and items or {}) do
    if type(item)=='table' and item.id then list[#list+1]=item end
  end
  if #list==0 then return false,'Choose loads to reserve.' end
  M.refreshOffers()
  local reserved,firstId,reason=0,nil,nil
  for _,item in ipairs(list) do
    local ok,msg,jobId=M.reserve(item.id,item.signature,true)
    if not ok then reason=msg; break end
    reserved=reserved+1; firstId=firstId or jobId
  end
  if reserved==0 then return false,reason or 'Nothing could be reserved.' end
  if reserved<#list then return true,reserved..' of '..#list..' loads reserved. '..(reason or ''),firstId end
  return true,reserved==1 and 'Load reserved.' or reserved..' loads reserved.',firstId
end
function M.pickupBatch(items,callback)
  local function finish(ok,message)
    busy=false; syncJobs(); refreshPois()
    if callback then callback(ok,message) end
  end
  if busy or employed() then return false,'Collection is unavailable right now.' end
  local plan,seen={},{}
  for _,item in pairs(type(items)=='table' and items or {}) do
    local job=type(item)=='table' and state.jobs[item.id]
    if job and not seen[job.id] then
      seen[job.id]=true
      if job.kind~='parcel' or job.map~=mapId() or (job.status~='reserved' and job.status~='active') then return false,'A parcel is no longer reserved. Refresh and retry.' end
      if not near(job.origin) then return false,'Drive to the marked pickup first.' end
      plan[#plan+1]={job=job,key=tostring(item.container or '')}
    end
  end
  if #plan==0 then return false,'Choose at least one parcel to load.' end
  if #(parcels().getTransientMoveCargo() or {})>0 then return false,'Finish the existing loading operation first.' end
  busy=true
  general().getNearbyVehicleCargoContainers(function(containers)
    if employed() then finish(false,'Collection is unavailable right now.'); return end
    local boxes={}
    for _,con in ipairs(containers or {}) do boxes[tostring(con.vehId)..':'..tostring(con.containerId)]={con=con,left=con.freeCargoSlots or 0} end
    local emp=career_modules_delivery_employment
    for _,p in ipairs(plan) do
      local box=boxes[p.key]
      local c=findParcel(p.job)
      local title=p.job.title or 'A parcel'
      if not near(p.job.origin) then finish(false,'Return to the pickup to load.'); return end
      if not box then finish(false,'A chosen cargo box is no longer nearby. Rescan and retry.'); return end
      if not c or c.location.type~='facilityParkingspot' or c.location.facId~=p.job.origin.facId then finish(false,title..' has already moved.'); return end
      if not box.con.cargoTypesLookup.parcel then finish(false,box.con.moveToLabel..' cannot carry parcels.'); return end
      if box.left<(c.slots or 0) then finish(false,'Not enough room in '..box.con.moveToLabel..' for '..title..'.'); return end
      if emp and emp.canMoveCargoOntoLocation and not emp.canMoveCargoOntoLocation(c.id,box.con.location) then finish(false,'This vehicle cannot accept independent cargo.'); return end
      box.left=box.left-(c.slots or 0); p.cargo=c; p.target=box.con.location
    end
    for _,p in ipairs(plan) do career_modules_delivery_cargoScreen.moveCargoFromUi(p.cargo.id,p.target) end
    career_modules_delivery_cargoScreen.commitDeliveryConfiguration(function()
      local loaded=0
      for _,p in ipairs(plan) do
        local moved=findParcel(p.job)
        if moved and moved.location.type=='vehicle' then loaded=loaded+1 end
      end
      if loaded==#plan then finish(true,loaded==1 and 'Parcel loaded.' or loaded..' parcels loaded.')
      elseif loaded>0 then finish(false,loaded..' of '..#plan..' parcels loaded. Retry the rest at the pickup.')
      else finish(false,'Cargo could not be loaded. Retry at the pickup.') end
    end)
  end)
  return true,'Loading '..#plan..(#plan==1 and ' parcel…' or ' parcels…')
end
-- "Load now" at a pickup: unreserved parcel offers here are reserved and loaded in the same step, together
-- with any reservations already waiting here. items: {{offer=offerId,signature=...,container=...} or {id=jobId,container=...}}
-- Reservations made here for parcels that end up not loaded are released again, so nothing is left held.
function M.loadHere(items,callback)
  if busy or employed() then return false,'Collection is unavailable right now.' end
  local list={}
  for _,item in ipairs(type(items)=='table' and items or {}) do
    if type(item)=='table' and (item.offer or item.id) then list[#list+1]=item end
  end
  if #list==0 then return false,'Choose at least one parcel to load.' end
  local created,batch={},{}
  local function release()
    for _,jobId in ipairs(created) do
      local job=state.jobs[jobId]
      if job and job.status=='reserved' then M.cancel(jobId) end
    end
  end
  M.refreshOffers()
  for _,item in ipairs(list) do
    if item.offer then
      local row=offers[item.offer]
      if not row or row.kind~='parcel' or not near(row.origin) then release(); return false,'A parcel here is no longer available. Refresh and retry.' end
      local ok,msg,jobId=M.reserve(item.offer,item.signature,true)
      if not ok then release(); return false,msg end
      created[#created+1]=jobId; batch[#batch+1]={id=jobId,container=item.container}
    else
      batch[#batch+1]={id=item.id,container=item.container}
    end
  end
  local ok,message=M.pickupBatch(batch,function(done,msg)
    release()
    if callback then callback(done,msg) end
  end)
  if not ok then release() end
  return ok,message
end
local function vehiclePreview(vehId)
  local ok,preview=pcall(function()
    local details=core_vehicles.getVehicleDetails(vehId)
    return details and details.configs and details.configs.preview
  end)
  return ok and preview or nil
end
function M.requestContainers(callback)
  general().getNearbyVehicleCargoContainers(function(containers)
    local result,previews={},{}
    for _,c in ipairs(containers or {}) do
      if previews[c.vehId]==nil then previews[c.vehId]=vehiclePreview(c.vehId) or false end
      result[#result+1]={key=tostring(c.vehId)..':'..tostring(c.containerId),name=c.moveToLabel,free=c.freeCargoSlots,
        capacity=c.totalCargoSlots,types=c.cargoTypesLookup,material=c.rawCargo[1] and c.rawCargo[1].materialType,
        vehId=c.vehId,vehName=c.vehName,boxName=c.name,preview=previews[c.vehId] or nil,attachment=c.attachmentStatus}
    end
    callback(result)
  end)
end

local function depot()
  local function commercial(fac)
    if not fac then return false end
    local org=fac.associatedOrganization and freeroam_organizations.getOrganization(fac.associatedOrganization)
    return require('gameplay/delivery/brokerFacilityRouting').shouldOpen(fac,org)
  end
  local id=state.depots[mapId()]
  local fac=id and gen().getFacilityById(id)
  if not commercial(fac) then
    fac=gen().getFacilityById('brokerCommercialDepot')
    if not commercial(fac) then
      local candidates={}
      for _,candidate in ipairs(gen().getFacilities()) do
        if commercial(candidate) then candidates[#candidates+1]=candidate end
      end
      fac=rules.chooseDepot(candidates)
    end
    state.depots[mapId()]=fac and fac.id or nil
  end
  return fac
end
local function depotLocation(fac)
  local spot=fac and ((fac.inspectSpots or {})[1] or (fac.pickUpSpots or {})[1] or (fac.loanerNonTrailerSpots or {})[1])
  return spot and {type='facilityParkingspot',facId=fac.id,psPath=spot:getPath()}
end
function M.getDepotView()
  local fac=depot(); local loc=depotLocation(fac)
  return fac and {id=fac.id,name=text(fac.name),location=loc,atDepot=loc and near(loc) or false} or nil
end
function M.navigateDepot()
  local pos=position(depotLocation(depot()))
  if not pos then return false,'No depot is available on this map.' end
  general().setDeliveryNavFocus(pos); core_groundMarkers.setPath({pos},{clearPathOnReachingTarget=false})
  return true,'Route to depot set.'
end
function M.getLoanerCatalog()
  local result={}
  local config=jsonReadFile('/gameplay/loaners/broker.json') or {}
  local day=math.floor(now()/86400)
  for _,item in ipairs(config.vehicles or {}) do
    local info=core_vehicles.getConfig(item.model,item.config)
    if info and (item.basic or (day+(item.rotation or 0))%2==0) then
      local row=deepcopy(item)
      row.rate=rules.dailyRate(career_modules_loanerVehicles.getHourlyRateForOffer(item,info),item.id,day)
      row.preview=info.preview; row.capacity=info.capacity
      result[#result+1]=row
    end
  end
  return result
end
function M.reserveRental(id)
  if employed() then return false,'Job Broker is for independent contractors.' end
  local fac=depot()
  if not fac then return false,'No depot is available on this map.' end
  for _,item in ipairs(M.getLoanerCatalog()) do
    if item.id==id then
      local rental=deepcopy(item); rental.id=nextId('rental'); rental.catalogId=id
      rental.status='reserved'; rental.map=mapId(); rental.depotId=fac.id
      state.rentals[rental.id]=rental
      return true,'Equipment reserved. Collect it at the depot.'
    end
  end
  return false,'This equipment is no longer available.'
end
function M.navigateRental(id)
  local rental=state.rentals[id]
  if not rental or rental.status~='rented' or rental.map~=mapId() then
    return false,'Select collected equipment on this map.'
  end
  local invId=inventoryRental(id)
  local vehId=invId and career_modules_inventory.getVehicleIdFromInventoryId(invId)
  local veh=vehId and be:getObjectByID(vehId)
  if not veh then return false,'This vehicle is not currently available on the map.' end
  local pos=veh:getPosition()
  general().setDeliveryNavFocus(pos)
  core_groundMarkers.setPath({pos},{clearPathOnReachingTarget=false})
  return true,'Waypoint set to '..rental.name..'.'
end
local function rentalVehicleSpawned(invId)
  if not invId then return false end
  local vehId=career_modules_inventory.getVehicleIdFromInventoryId(invId)
  return vehId and be:getObjectByID(vehId) and true or false
end
local function clearRentalRecord(id)
  state.rentals[id]=nil
end
function M.getRentals()
  reconcileRentals()
  local out={}
  for id,r in pairs(state.rentals) do
    if r.status~='returned' then
      local row=deepcopy(r)
      row.vehicleSpawned=rentalVehicleSpawned(inventoryRental(id))
      out[#out+1]=row
    end
  end
  table.sort(out,function(a,b)return a.id<b.id end)
  return out
end
function M.cancelRental(id)
  if busy then return false,'Finish the current equipment handoff first.' end
  local r=state.rentals[id]
  if not r or r.status~='reserved' or inventoryRental(id) then return false,'Return collected equipment at the depot.' end
  state.rentals[id]=nil; return true,'Rental booking cancelled.'
end
local function dismissCollectUi()
  if gameplay_phone and gameplay_phone.closePhone then gameplay_phone.closePhone() end
  if guihooks then guihooks.trigger('ChangeState',{state='play'}) end
  if gameplay_markerInteraction and gameplay_markerInteraction.closeViewDetailPrompt then
    gameplay_markerInteraction.closeViewDetailPrompt(true)
  end
end

function M.collectRental(id,callback)
  local r=state.rentals[id]
  if busy or employed() or not r or r.status~='reserved' or inventoryRental(id) then return false,'Rental cannot be collected.' end
  local fac=r.map==mapId() and gen().getFacilityById(r.depotId)
  if not fac or not near(depotLocation(fac)) then return false,'Go to your collection depot first.' end
  local loaners=career_modules_loanerVehicles
  if loaners.hasMarkedOffers and loaners.hasMarkedOffers() then return false,'Finish the other vehicle collection first.' end
  busy=true
  dismissCollectUi()
  local offer={id=r.id,model=r.model,config=r.config,vehMileage=0,loanType='rental',hourlyRate=r.rate,
    sourceFacility={type='deliveryProvider',id=fac.id},brokerRentalId=id,brokerDepotId=fac.id,brokerMap=mapId()}
  loaners.setMarkedForSpawning(offer,true)
  loaners.spawnAllOffers(function()
    busy=false
    local invId=inventoryRental(id)
    if invId then r.status='rented'; r.inventoryId=invId end
    if callback then callback(invId~=nil,invId and 'Rental collected.' or 'No safe collection space. Clear the bay and retry.') end
  end)
  return true,'Collecting equipment…'
end
function M.onRentalVehicleReturned(rentalId)
  if rentalId then clearRentalRecord(tostring(rentalId)) end
end
function M.returnRental(id,callback)
  local r=state.rentals[id]
  if busy or not r or r.map~=mapId() then return false,'This rental is not available here.' end
  local fac=gen().getFacilityById(r.depotId)
  local loc=depotLocation(fac)
  if not loc or not near(loc) then return false,'Go to your collection depot first.' end
  local invId=inventoryRental(id)
  if not invId then
    if r.status~='rented' then return false,'This rental is not available here.' end
    clearRentalRecord(id)
    if callback then callback(true,'Rental cleared.') end
    return true,'Rental cleared.'
  end
  local vehId=career_modules_inventory.getVehicleIdFromInventoryId(invId)
  local veh=vehId and be:getObjectByID(vehId)
  if veh then
    local pos=position(loc)
    if not pos or (veh:getPosition()-pos):length()>40 then return false,'Bring this vehicle back to its depot.' end
    local tasks=career_modules_delivery_vehicleTasks
    if tasks and tasks.canReturnBrokerEquipment then
      local ok,message=tasks.canReturnBrokerEquipment(vehId)
      if not ok then return false,message end
    end
    for _,c in ipairs(parcels().getAllCargoInVehicles() or {}) do
      if c.location.vehId==vehId then return false,'Unload cargo before returning this vehicle.' end
    end
  end
  busy=true
  career_modules_loanerVehicles.returnVehicle(invId,function()
    busy=false
    local settled=not inventoryRental(id)
    if settled then clearRentalRecord(id) end
    if callback then callback(settled,settled and 'Rental returned and bill settled.' or 'Rental could not be returned.') end
  end)
  return true,'Returning equipment…'
end

return M
