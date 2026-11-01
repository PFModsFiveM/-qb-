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

The level other players see is a state bag only the server writes. A client's `SetFuel` sets the
car's level on that client and reports it; the server takes the report only from the car's
driver, only downward and no faster than `Config.MaxFuelBurnPerSecond` (a car with no level yet
takes its driver's first report). Pump refills and jerry cans raise it on the server. Server code
that spawns a car can give it its first level with `exports['pfm-fuel']:SetVehicleFuel(veh, level)`.

## Compatibility

This resource is fully compatible with QBCore servers and it sustitutes the _[LegacyFuel](https://github.com/InZidiuZ/LegacyFuel)_, thanks to InZidiuZ for that amazing script that inspired us to make a new Fuel System script.

```lua
-- Will return the same
exports['pfm-fuel']:GetFuel(vehicle)
exports['LegacyFuel']:GetFuel(vehicle)
```

This will make it easier to change from _LegacyFuel_ to _qb-fuel_.
