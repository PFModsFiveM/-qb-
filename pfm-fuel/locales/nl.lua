local Translations = {
    progress = {
        refueling = 'Voertuig aan het voltanken...',
    },
    success = {
        refueled = 'Voertuig is volgetankt',
    },
    error = {
        no_money = 'Je hebt niet genoeg geld',
        no_vehicle = 'Geen voertuig in de buurt gevonden!',
        no_vehicles = 'Er zijn geen voertuigen in de buurt',
        no_jerrycan = 'Je hebt geen jerrycan met benzine',
        vehicle_full = 'Het voertuig is al volgetankt',
        vehicle_busy = 'Iemand anders tankt dit voertuig al',
        not_networked = 'Dit voertuig kan niet worden getankt: het bestaat alleen op jouw scherm',
        no_station = 'Benzine wordt alleen bij een tankstation verkocht',
        payment_declined = 'De betaling is niet gelukt. Er is niets afgeschreven.',
        refunded = 'De brandstof kon niet in het voertuig. Je betaling is terugbetaald.',
        refund_pending = 'De bank heeft je brandstofterugbetaling nog niet verwerkt. Die volgt bij je volgende tankbeurt.',
        no_fuel_can = 'Er zit geen benzine in de jerrycan',
        no_nozzle = 'Er is geen voertuig met een aangesloten slang in de buurt',
        too_far = 'Je bent te ver van de pomp, de slang is teruggeplaatst',
        wrong_side = 'De tankdop van het voertuig zit aan de andere kant',
    },
    target = {
        put_fuel = 'Benzine tanken',
        get_nozzle = 'Slang pakken',
        buy_jerrycan = 'Jerrycan kopen $%{price}',
        refill_jerrycan = 'Jerrycan bijvullen $%{price}',
        refill_fuel = 'Benzine bijvullen',
        nozzle_put = 'Slang aansluiten',
        nozzle_remove = 'Slang loskoppelen',
        return_nozzle = 'Slang terugplaatsen',
    }
}

if GetConvar('qb_locale', 'en') == 'nl' then
    Lang = Locale:new({
        phrases = Translations,
        warnOnMissing = true,
        fallbackLang = Lang,
    })
end
