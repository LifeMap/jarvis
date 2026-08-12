import { useCallback, useEffect, useState } from "react";
import type { RequestLocation } from "../types/agent";

export function useLocationContext(){
  const supported=typeof navigator!=="undefined"&&"geolocation" in navigator;
  const[location,setLocation]=useState<RequestLocation>();
  const[status,setStatus]=useState<"unsupported"|"requesting"|"available"|"denied"|"error">(supported?"requesting":"unsupported");
  const refresh=useCallback(()=>{
    if(!supported)return;
    setStatus("requesting");
    navigator.geolocation.getCurrentPosition(position=>{
      setLocation({latitude:position.coords.latitude,longitude:position.coords.longitude,accuracyMeters:position.coords.accuracy,capturedAt:new Date(position.timestamp).toISOString(),source:"browser"});
      setStatus("available");
    },error=>{setLocation(undefined);setStatus(error.code===error.PERMISSION_DENIED?"denied":"error")},{enableHighAccuracy:false,maximumAge:5*60_000,timeout:10_000});
  },[supported]);
  useEffect(()=>{refresh()},[refresh]);
  return{supported,status,location,refresh};
}
