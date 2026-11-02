let veh

$(document).on('click', '.garage-vehicle', function(e){
    e.preventDefault();

    $(".garage-homescreen").animate({
        left: 30+"vh"
    }, 200);
    $(".garage-detailscreen").animate({
        left: 0+"vh"
    }, 200);

    var Id = $(this).attr('id');
    var VehData = $("#"+Id).data('VehicleData');
    veh = VehData
    SetupDetails(VehData);
});

$(document).on('click', '#track-vehicle', function(e){
    e.preventDefault()
    $.post("https://pfm-phone/track-vehicle", JSON.stringify({
        veh: veh,
    }));
});


$(document).on('click', '#return-button', function(e){
    e.preventDefault();

    $(".garage-homescreen").animate({
        left: 00+"vh"
    }, 200);
    $(".garage-detailscreen").animate({
        left: -30+"vh"
    }, 200);
});

SetupGarageVehicles = function(Vehicles) {
    $(".garage-vehicles").html("");
    if (Vehicles != null) {
        $.each(Vehicles, function(i, vehicle){
            var Element = '<div class="garage-vehicle" id="vehicle-'+i+'"><span class="garage-vehicle-firstletter">'+QB.Phone.Esc(String(vehicle.brand || '').charAt(0))+'</span> <span class="garage-vehicle-name">'+QB.Phone.Esc(vehicle.fullname)+'</span> </div>';

            $(".garage-vehicles").append(Element);
            $("#vehicle-"+i).data('VehicleData', vehicle);
        });
    }
}

SetupDetails = function(data) {
    $(".vehicle-brand").find(".vehicle-answer").text(data.brand === undefined || data.brand === null ? "" : data.brand);
    $(".vehicle-model").find(".vehicle-answer").text(data.model === undefined || data.model === null ? "" : data.model);
    $(".vehicle-plate").find(".vehicle-answer").text(data.plate === undefined || data.plate === null ? "" : data.plate);
    $(".vehicle-garage").find(".vehicle-answer").text(data.garage === undefined || data.garage === null ? "" : data.garage);
    $(".vehicle-status").find(".vehicle-answer").html(data.state);
    $(".vehicle-fuel").find(".vehicle-answer").html(Math.ceil(data.fuel)+"%");
    $(".vehicle-engine").find(".vehicle-answer").html(Math.ceil(data.engine / 10)+"%");
    $(".vehicle-body").find(".vehicle-answer").html(Math.ceil(data.body / 10)+"%");
}