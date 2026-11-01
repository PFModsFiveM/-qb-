local Translations = {
    error = {
        not_your_vehicle = 'This is not your vehicle..',
        vehicle_does_not_exist = 'Vehicle does not exist',
        not_enough_money = 'You dont have enough money',
        finish_payments = 'You must finish paying off this vehicle, Before you can sell it..',
        no_space_on_lot = 'There is not space for your car on the lot!',
        not_in_veh = 'You are not in a vehicle!',
        not_for_sale = 'This vehicle is NOT for sale!',
        fleet_vehicle = 'This vehicle belongs to a job fleet. Take it out of the fleet first.',
        impounded = 'This vehicle is impounded. Pay its impound fee first.',
        lot_unavailable = 'The lot cannot take this right now. Nothing was changed.',
        lot_busy = 'The lot is handling another sale. Try again in a moment.',
        payment_waiting = 'A car purchase of yours is still waiting on the bank. Try again once it clears.',
        bank_unavailable = 'The bank is not available right now. Nothing was charged.',
        sellback_unpaid = 'The bank could not pay for the car right now. You keep your car.',
    },
    menu = {
        view_contract = 'View Contract',
        view_contract_int = '[E] View Contract',
        sell_vehicle = 'Sell Vehicle',
        sell_vehicle_help = 'Sell vehicle to fellow citizens!',
        sell_back = 'Sell back car!',
        sell_back_help = 'Sell your car straight back for a reduced price!',
        interaction = '[E] Sell Vehicle',
    },
    success = {
        sold_car_for_price = 'You have sold your car for $%{value}',
        car_up_for_sale = 'Your car has been put up for sale! Price - $%{value}',
        vehicle_bought = 'Vehicle Bought',
    },
    info = {
        confirm_cancel = '~g~Y~w~ - Confirm / ~r~N~w~ - Cancel ~g~',
        vehicle_returned = 'Your vehicle is returned',
        used_vehicle_lot = 'Used Car Lot',
        sell_vehicle_to_dealer = '[~g~E~w~] - Sell Vehicle To Dealer For ~g~$%{value}',
        view_contract = '[~g~E~w~] - View Vehicle Contract',
        cancel_sale = '[~r~G~w~] - Cancel Vehicle Sale',
        model_price = '%{value}, Price: ~g~$%{value2}',
        are_you_sure = 'Are you sure you no longer want to sell your vehicle?',
        yes_no = '[~g~7~w~] - Yes | [~r~8~w~] - No',
        place_vehicle_for_sale = '[~g~E~w~] - Place Vehicle For Sale By Owner',
        -- a charge the bank has not confirmed yet: no car now, never charged again, settled on its own
        payment_held = 'Your bank has not confirmed this payment yet. You will not be charged again. The car is held for you: when the payment clears it is parked at %{garage}; if it does not, the car goes back on the lot and nothing is taken. Reference %{ref}.',
        payment_held_gone = 'Your bank has not confirmed this payment yet, and the car was sold or changed meanwhile. You will not be charged again: if the payment clears, the money is returned to you. Reference %{ref}.',
        payment_held_pending = 'Your bank has not confirmed this payment yet. You will not be charged again. When it clears, the car is parked for you at %{garage} if it is still for sale, or the money is returned; if it does not clear, nothing is taken. Reference %{ref}.',
        -- paid, but the lot's database failed while handing the car over: the sweep finishes it
        purchase_finishing = 'Your payment went through, but the lot could not hand the car over just now. The sale finishes on its own within a few minutes: the car is parked for you at %{garage}, or, if it is no longer for sale, your money is returned. Reference %{ref}.',
        sold_back_pending = 'You sold your car to the lot for $%{value}. The bank is still processing the payment; it reaches your account automatically.',
        held_subject = 'Your used car purchase',
        held_delivered = 'Your payment cleared. The %{vehicle} (%{plate}) is parked for you at %{garage}.',
        held_refunded = 'Your payment cleared, but the %{vehicle} was no longer for sale. Your $%{amount} is returned to you.',
        held_cancelled = 'The bank did not take the payment for the %{vehicle}. The car is back on the lot and nothing was charged.',
        held_review = 'The bank could not confirm whether the payment for the %{vehicle} left your account. Nothing was delivered and the car is back on the lot. If the money is gone, contact staff with reference %{ref}.',
    },
    charinfo = {
        firstname = 'not',
        lastname = 'known',
        account = 'Account not known..',
        phone = 'telephone number not known..',
    },
    mail = {
        sender = 'Larrys RV Sales',
        subject = 'You have sold a vehicle!',
        message = 'You made $%{value} from the sale of your %{value2}.',
    }
}

Lang = Lang or Locale:new({
    phrases = Translations,
    warnOnMissing = true
})
