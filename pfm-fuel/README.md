# qb-fuel

Fuel and fuelstations system for Fivem :fuelpump:

## Dependencies

-   [qb-core](https://github.com/qbcore-framework/qb-core) (Required)
-   [qb-target](https://github.com/BerkieBb/qb-target) (Required)
-   [PolyZone](https://github.com/mkafrin/PolyZone) (Required)

## Exports 📡

|  Name   | Namespace |    Arguments    | Return |
| :-----: | :-------: | :-------------: | :----: |
| GetFuel |  Client   |     vehicle     | number |
| SetFuel |  Client   | vehicle, number |  void  |
| SetVehicleFuel | Server | vehicle entity, number | boolean |
| GetVehicleFuel | Server | vehicle entity | number or nil |

_\* The exports can be use with the resource name (qb-fuel) or with LegacyFuel_

The level other players see is a state bag only the server writes. A car's first level comes from
the server: the level stored for its plate in `player_vehicles.fuel` (an owned car, as it was
parked), else `Config.DefaultFuel` (a new, job, rented or stolen car). Its driver's first report
only prompts that lookup. After that a client's `SetFuel` sets the car's level on that client and
reports it; the server takes the report only from the car's driver, only downward and no faster
than `Config.MaxFuelBurnPerSecond`. Pump refills and jerry cans raise it on the server. Server
code that spawns a car can set its first level itself with
`exports['pfm-fuel']:SetVehicleFuel(veh, level)`; that value wins over the lookup.

Pumps sell (refills, jerry can purchases and refills) only where the server knows a station:
within 60 m of one of `Config.GasStations`, or within `Config.ExtraPumpRadius` of one of
`Config.ExtraPumps` (add pumps the station list misses there). The server cannot see pump props.
A jerry can pours into a car anywhere. A car that exists only on one client (not networked)
cannot be refuelled; the player is told so.

## Compatibility

This resource is fully compatible with QBCore servers and it sustitutes the _[LegacyFuel](https://github.com/InZidiuZ/LegacyFuel)_, thanks to InZidiuZ for that amazing script that inspired us to make a new Fuel System script.

```lua
-- Will return the same
exports['pfm-fuel']:GetFuel(vehicle)
exports['LegacyFuel']:GetFuel(vehicle)
```

This will make it easier to change from _LegacyFuel_ to _qb-fuel_.
