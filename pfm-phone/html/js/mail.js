var OpenedMail = null;

$(document).on('click', '.mail', function(e){
    e.preventDefault();

    $(".mail-home").animate({
        left: 30+"vh"
    }, 300);
    $(".opened-mail").animate({
        left: 0+"vh"
    }, 300);

    var MailData = $("#"+$(this).attr('id')).data('MailData');
    QB.Phone.Functions.SetupMail(MailData);

    OpenedMail = $(this).attr('id');
});

$(document).on('click', '.mail-back', function(e){
    e.preventDefault();

    $(".mail-home").animate({
        left: 0+"vh"
    }, 300);
    $(".opened-mail").animate({
        left: -30+"vh"
    }, 300);
    OpenedMail = null;
});

$(document).on('click', '#accept-mail', function(e){
    e.preventDefault();
    var MailData = $("#"+OpenedMail).data('MailData');
    $.post('https://pfm-phone/AcceptMailButton', JSON.stringify({
        buttonEvent: MailData.button.buttonEvent,
        buttonData: MailData.button.buttonData,
        mailId: MailData.mailid,
    }));
    $(".mail-home").animate({
        left: 0+"vh"
    }, 300);
    $(".opened-mail").animate({
        left: -30+"vh"
    }, 300);
});

$(document).on('click', '#remove-mail', function(e){
    e.preventDefault();
    var MailData = $("#"+OpenedMail).data('MailData');
    $.post('https://pfm-phone/RemoveMail', JSON.stringify({
        mailId: MailData.mailid
    }));
    $(".mail-home").animate({
        left: 0+"vh"
    }, 300);
    $(".opened-mail").animate({
        left: -30+"vh"
    }, 300);
});

QB.Phone.Functions.SetupMails = function(Mails) {
    var NewDate = new Date();
    var NewHour = NewDate.getHours();
    var NewMinute = NewDate.getMinutes();
    var Minutessss = NewMinute;
    var Hourssssss = NewHour;
    if (NewHour < 10) {
        Hourssssss = "0" + Hourssssss;
    }
    if (NewMinute < 10) {
        Minutessss = "0" + NewMinute;
    }
    var MessageTime = Hourssssss + ":" + Minutessss;

    $("#mail-header-mail").text(QB.Phone.Data.PlayerData.charinfo.firstname+"."+QB.Phone.Data.PlayerData.charinfo.lastname+"@qbcore.com");
    $("#mail-header-lastsync").text("Last synchronized "+MessageTime);
    if (Mails !== null && Mails !== undefined) {
        if (Mails.length > 0) {
            $(".mail-list").html("");
            // mails can come from other players (pf-citizen): sender as text, the body with basic
            // formatting only (SafeHtml)
            $.each(Mails, function(i, mail){
                var date = new Date(mail.date);
                var DateString = date.getDate()+" "+MonthFormatting[date.getMonth()]+" "+date.getFullYear()+" "+date.getHours()+":"+date.getMinutes();
                var element = $('<div class="mail"><span class="mail-sender" style="font-weight: bold;"></span> <div class="mail-text"><p></p></div> <div class="mail-time"></div></div>');
                element.attr('id', 'mail-' + i);
                element.find('.mail-sender').text(mail.sender === undefined || mail.sender === null ? '' : mail.sender);
                element.find('.mail-text p').html(QB.Phone.SafeHtml(mail.message));
                element.find('.mail-time').text(DateString);

                $(".mail-list").append(element);
                element.data('MailData', mail);
            });
        } else {
            $(".mail-list").html('<p class="nomails">You don\'t have any mails..</p>');
        }

    }
}

var MonthFormatting = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

QB.Phone.Functions.SetupMail = function(MailData) {
    var date = new Date(MailData.date);
    var DateString = date.getDate()+" "+MonthFormatting[date.getMonth()]+" "+date.getFullYear()+" "+date.getHours()+":"+date.getMinutes();
    $(".mail-subject").html("<p><span style='font-weight: bold;'>"+QB.Phone.Esc(MailData.sender)+"</span><br>"+QB.Phone.Esc(MailData.subject)+"</p>");
    $(".mail-date").html("<p>"+QB.Phone.Esc(DateString)+"</p>");
    $(".mail-content").html("<p>"+QB.Phone.SafeHtml(MailData.message)+"</p>");

    var AcceptElem = '<div class="opened-mail-footer-item" id="accept-mail"><i class="fas fa-check-circle mail-icon"></i></div>';
    var RemoveElem = '<div class="opened-mail-footer-item" id="remove-mail"><i class="fas fa-trash-alt mail-icon"></i></div>';

    $(".opened-mail-footer").html("");

    if (MailData.button !== undefined && MailData.button !== null) {
        $(".opened-mail-footer").append(AcceptElem);
        $(".opened-mail-footer").append(RemoveElem);
        $(".opened-mail-footer-item").css({"width":"50%"});
    } else {
        $(".opened-mail-footer").append(RemoveElem);
        $(".opened-mail-footer-item").css({"width":"100%"});
    }
}

// Advert JS

$(document).on('click', '.test-slet', function(e){
    e.preventDefault();
    $(".advert-home").animate({
        left: 30+"vh"
    });
    $(".new-advert").animate({
        left: 0+"vh"
    });
});

$(document).on('click','.advimage', function (){
    let source = $(this).attr('src')
    QB.Screen.popUp(source);
});

$(document).on('click','#new-advert-photo',function(e){
    e.preventDefault();
    $.post('https://pfm-phone/TakePhoto',function(url){
        if(url){
            $('#advert-new-url').val(url)
        }
    })
    QB.Phone.Functions.Close();
});

$(document).on('click', '#new-advert-back', function(e){
    e.preventDefault();

    $(".advert-home").animate({
        left: 0+"vh"
    });
    $(".new-advert").animate({
        left: -30+"vh"
    });
});

$(document).on('click', '#new-advert-submit', function(e){
    e.preventDefault();
    var Advert = $(".new-advert-textarea").val();
    let picture = $('#advert-new-url').val();

    if (Advert !== "") {
        $(".advert-home").animate({
            left: 0+"vh"
        });
        $(".new-advert").animate({
            left: -30+"vh"
        });
        if (!picture){
            $.post('https://pfm-phone/PostAdvert', JSON.stringify({
                message: Advert,
                url: null
            }));
        }else {
            $.post('https://pfm-phone/PostAdvert', JSON.stringify({
                message: Advert,
                url: picture
            }));
        }
        $('#advert-new-url').val("")
        $(".new-advert-textarea").val("");
    } else {
        QB.Phone.Notifications.Add("fas fa-ad", "Advertisement", "You can\'t post an empty ad!", "#ff8f1a", 2000);
    }
});

QB.Phone.Functions.RefreshAdverts = function(Adverts) {
    $("#advert-header-name").text("@"+QB.Phone.Data.PlayerData.charinfo.firstname+""+QB.Phone.Data.PlayerData.charinfo.lastname+" | "+QB.Phone.Data.PlayerData.charinfo.phone);
    if (Adverts && (Adverts.length > 0 || Adverts.length == undefined)) {
        $(".advert-list").html("");
        // adverts go to every phone: the poster's name, number, text and picture as text/checked link
        $.each(Adverts, function(i, advert){
            var element = $('<div class="advert"><span class="advert-sender"></span><p></p></div>');
            element.find('.advert-sender').text(String(advert.name || '') + ' | ' + String(advert.number || ''));
            element.find('p').text(advert.message === undefined || advert.message === null ? '' : advert.message);
            var url = advert.url ? QB.Phone.SafeUrl(advert.url, null) : null;
            if (url) {
                element.append('</br>');
                element.append($('<img class="advimage" style=" border-radius:4px; width: 95%; position:relative; z-index: 1; right:1px;height: auto; bottom:1vh;">').attr('src', url));
                element.append('</br><span><div class="adv-icon"></div> </span>');
            }

            $(".advert-list").append(element);

            if (advert.number === QB.Phone.Data.PlayerData.charinfo.phone){
                element.append('<i class="fas fa-trash"style="font-size: 1rem; right:0;" id="adv-delete"></i>')
            }
        });
    } else {
        $(".advert-list").html("");
        var element = '<div class="advert"><span class="advert-sender">There are no advertisements yet!</span></div>';
        $(".advert-list").append(element);
    }
}

$(document).on('click','#adv-delete',function(e){
    e.preventDefault();
    $.post('https://pfm-phone/DeleteAdvert', function(){
        setTimeout(function(){
            QB.Phone.Notifications.Add("fas fa-ad", "Advertisement", "The ad was deleted", "#ff8f1a", 2000);
        },400)
    });
})
