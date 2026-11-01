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
| GetVehicleFuel | Server | vehicle entity, plate (optional) | number or nil |
| UseStoredFuel | Server | vehicle entity, plate | boolean |
| IsFuelSynced | Server | | boolean |

_\* The exports can be use with the resource name (qb-fuel) or with LegacyFuel_

The level other players see is a state bag only the server writes. A car's first level comes from
the server: the level stored for its plate in `player_vehicles.fuel` (an owned car, as it was
parked), else `Config.DefaultFuel` (a new, job, rented or stolen car). Its driver's first report
only prompts that lookup. After that a client's `SetFuel` sets the car's level on that client and
reports it; the server takes the report only from the car's driver, only downward and no faster
than `Config.MaxFuelBurnPerSecond`. Pump refills and jerry cans raise it on the server. Server
code that spawns a car can set its first level itself with
`exports['pfm-fuel']:SetVehicleFuel(veh, level)`; that value wins over the lookup. Server code
that spawns an owned car names its row with `exports['pfm-fuel']:UseStoredFuel(veh, plate)`
(pfm-garages does): the car starts at that row's level at once, whatever plate the owner's
client shows later (a plate the server sets reaches it only through that client).

Each level remembers the plate it was given for. `GetVehicleFuel(veh, plate)` answers only when
the car's level was given for that plate, so a car showing another car's plate does not answer
for it; pfm-garages saves a parked car's fuel only up to that level, and with no such car the
client can only lower what is stored. `IsFuelSynced()` says whether the server keeps levels
(`Config.SyncFuelBetweenPlayers`).

Pumps sell (refills, jerry can purchases and refills) only where the server knows a station:
within 60 m of one of `Config.GasStations`, or within `Config.ExtraPumpRadius` of one of
`Config.ExtraPumps` (add pumps the station list misses there). The server cannot see pump props.
A jerry can pours into a car anywhere. A car that exists only on one client (not networked)
cannot be refuelled; the player is told so. A refuel landing while a car's first level is looked
up waits for the lookup (up to 5 s).

Sales go through the pfm-banking ledger, one key per sale. A charge whose outcome the bank does
not know yet (pending) is never charged again under a new key: the player's next purchase of the
same kind (pump, jerry can, can refill) asks the bank again under that key and amount and hands
over what it paid for once it went through. A paid refill that cannot go into the car (the car
was removed during the payment, or a settled earlier refill no longer fits) is refunded under the
charge's key plus `:refund`; a refund the bank does not take is paid before the player's next
refill. These are kept in memory (a restart forgets them; the ledger's recovery still settles
the charges).

## Compatibility

This resource is fully compatible with QBCore servers and it sustitutes the _[LegacyFuel](https://github.com/InZidiuZ/LegacyFuel)_, thanks to InZidiuZ for that amazing script that inspired us to make a new Fuel System script.

```lua
-- Will return the same
exports['pfm-fuel']:GetFuel(vehicle)
exports['LegacyFuel']:GetFuel(vehicle)
```

This will make it easier to change from _LegacyFuel_ to _qb-fuel_.
