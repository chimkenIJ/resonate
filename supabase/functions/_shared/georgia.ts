// The only area Resonate has map data for: the US state of Georgia.
// Fast bounding-box check; the database's in_service_area() holds the exact outline.

export const GEORGIA = { minLat: 30.3558, maxLat: 35.0008, minLon: -85.6052, maxLon: -80.7514 };

export const OUTSIDE_GEORGIA_MESSAGE =
  "That place is outside Georgia. Resonate only has maps for Georgia right now.";

export function inGeorgia(lat: number, lon: number): boolean {
  return lat >= GEORGIA.minLat && lat <= GEORGIA.maxLat && lon >= GEORGIA.minLon && lon <= GEORGIA.maxLon;
}

/** Great-circle distance in meters. */
export function haversine(lat1: number, lon1: number, lat2: number, lon2: number): number {
  const r = 6_371_000;
  const toRad = (d: number) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return r * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}
