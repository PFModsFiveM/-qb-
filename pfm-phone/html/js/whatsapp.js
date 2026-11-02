var WhatsappSearchActive = false;
var OpenedChatPicture = null;
var ExtraButtonsOpen = false;

$(document).ready(function(){
    $("#whatsapp-search-input").on("keyup", function() {
        var value = $(this).val().toLowerCase();
        $(".whatsapp-chats .whatsapp-chat").filter(function() {
          $(this).toggle($(this).text().toLowerCase().indexOf(value) > -1);
        });
    });
});

$(document).on('click', '#whatsapp-search-chats', function(e){
    e.preventDefault();

    if ($("#whatsapp-search-input").css('display') == "none") {
        $("#whatsapp-search-input").fadeIn(150);
        WhatsappSearchActive = true;
    } else {
        $("#whatsapp-search-input").fadeOut(150);
        WhatsappSearchActive = false;
    }
});

$(document).on('click', '.whatsapp-chat', function(e){
    e.preventDefault();

    var ChatId = $(this).attr('id');
    var ChatData = $("#"+ChatId).data('chatdata');

    QB.Phone.Functions.SetupChatMessages(ChatData);

    $.post('https://pfm-phone/ClearAlerts', JSON.stringify({
        number: ChatData.number
    }));

    if (WhatsappSearchActive) {
        $("#whatsapp-search-input").fadeOut(150);
    }

    $(".whatsapp-openedchat").css({"display":"block"});
    $(".whatsapp-openedchat").animate({
        left: 0+"vh"
    },200);

    $(".whatsapp-chats").animate({
        left: 30+"vh"
    },200, function(){
        $(".whatsapp-chats").css({"display":"none"});
    });

    $('.whatsapp-openedchat-messages').animate({scrollTop: 9999}, 150);

    if (OpenedChatPicture == null) {
        OpenedChatPicture = QB.Phone.SafeUrl(ChatData.picture);
        $(".whatsapp-openedchat-picture").css({"background-image": QB.Phone.CssUrl(OpenedChatPicture)});
    }
});

$(document).on('click', '#whatsapp-openedchat-back', function(e){
    e.preventDefault();
    $.post('https://pfm-phone/GetWhatsappChats', JSON.stringify({}), function(chats){
        QB.Phone.Functions.LoadWhatsappChats(chats);
    });
    OpenedChatData.number = null;
    $(".whatsapp-chats").css({"display":"block"});
    $(".whatsapp-chats").animate({
        left: 0+"vh"
    }, 200);
    $(".whatsapp-openedchat").animate({
        left: -30+"vh"
    }, 200, function(){
        $(".whatsapp-openedchat").css({"display":"none"});
    });
    OpenedChatPicture = null;
});

QB.Phone.Functions.GetLastMessage = function(messages) {
    var CurrentDate = new Date();
    var CurrentMonth = CurrentDate.getMonth();
    var CurrentDOM = CurrentDate.getDate();
    var CurrentYear = CurrentDate.getFullYear();
    var LastMessageData = {
        time: "00:00",
        message: "nothing"
    }

    // the last message of the last day (both escaped by the caller)
    var lastDay = messages && messages.length ? messages[messages.length - 1] : null;
    var dayMessages = lastDay && lastDay.messages;
    var msgData = dayMessages && dayMessages.length ? dayMessages[dayMessages.length - 1] : null;
    if (msgData) {
        LastMessageData.time = msgData.time || "";
        LastMessageData.message = msgData.message || "";
    }

    return LastMessageData
}

GetCurrentDateKey = function() {
    var CurrentDate = new Date();
    var CurrentMonth = CurrentDate.getMonth();
    var CurrentDOM = CurrentDate.getDate();
    var CurrentYear = CurrentDate.getFullYear();
    var CurDate = ""+CurrentDOM+"-"+CurrentMonth+"-"+CurrentYear+"";

    return CurDate;
}

QB.Phone.Functions.LoadWhatsappChats = function(chats) {
    if (chats === undefined || chats === null) return; // nothing to show: keep the list
    $(".whatsapp-chats").html("");
    var esc = QB.Phone.Esc;
    $.each(chats, function(i, chat){
        var LastMessage = QB.Phone.Functions.GetLastMessage(chat.messages);
        var ChatElement = '<div class="whatsapp-chat" id="whatsapp-chat-'+esc(i)+'"><div class="whatsapp-chat-picture"></div><div class="whatsapp-chat-name"><p>'+esc(chat.name)+'</p></div><div class="whatsapp-chat-lastmessage"><p>'+esc(LastMessage.message)+'</p></div> <div class="whatsapp-chat-lastmessagetime"><p>'+esc(LastMessage.time)+'</p></div><div class="whatsapp-chat-unreadmessages unread-chat-id-'+esc(i)+'">1</div></div>';

        $(".whatsapp-chats").append(ChatElement);
        // the avatar link is another player's setting: set through css(), only an https link
        $("#whatsapp-chat-"+i).find(".whatsapp-chat-picture").css({"background-image": QB.Phone.CssUrl(chat.picture)});
        $("#whatsapp-chat-"+i).data('chatdata', chat);

        if (chat.Unread > 0 && chat.Unread !== undefined && chat.Unread !== null) {
            $(".unread-chat-id-"+i).text(chat.Unread);
            $(".unread-chat-id-"+i).css({"display":"block"});
        } else {
            $(".unread-chat-id-"+i).css({"display":"none"});
        }
    });
}

QB.Phone.Functions.ReloadWhatsappAlerts = function(chats) {
    $.each(chats, function(i, chat){
        if (chat.Unread > 0 && chat.Unread !== undefined && chat.Unread !== null) {
            $(".unread-chat-id-"+i).text(chat.Unread);
            $(".unread-chat-id-"+i).css({"display":"block"});
        } else {
            $(".unread-chat-id-"+i).css({"display":"none"});
        }
    });
}

const monthNames = ["January", "February", "March", "April", "May", "June", "JulY", "August", "September", "October", "November", "December"];

FormatChatDate = function(date) {
    var TestDate = String(date || "").split("-");
    var NewDate = new Date((parseInt(TestDate[1]) + 1)+"-"+TestDate[0]+"-"+TestDate[2]);

    var CurrentMonth = monthNames[NewDate.getMonth()];
    var CurrentDOM = NewDate.getDate();
    var CurrentYear = NewDate.getFullYear();
    var CurDateee = CurrentDOM + "-" + NewDate.getMonth() + "-" + CurrentYear;
    var ChatDate = CurrentDOM + " " + CurrentMonth + " " + CurrentYear;
    var CurrentDate = GetCurrentDateKey();

    var ReturnedValue = ChatDate;
    if (CurrentDate == CurDateee) {
        ReturnedValue = "Today";
    }

    return ReturnedValue;
}

FormatMessageTime = function() {
    var NewDate = new Date();
    var NewHour = NewDate.getHours();
    var NewMinute = NewDate.getMinutes();
    var Minutessss = NewMinute;
    var Hourssssss = NewHour;
    if (NewMinute < 10) {
        Minutessss = "0" + NewMinute;
    }
    if (NewHour < 10) {
        Hourssssss = "0" + NewHour;
    }
    var MessageTime = Hourssssss + ":" + Minutessss
    return MessageTime;
}

$(document).on('click', '#whatsapp-openedchat-send', function(e){
    e.preventDefault();

    var Message = $("#whatsapp-openedchat-message").val();

    if (Message !== null && Message !== undefined && Message !== "") {
        $.post('https://pfm-phone/SendMessage', JSON.stringify({
            ChatNumber: OpenedChatData.number,
            ChatDate: GetCurrentDateKey(),
            ChatMessage: Message,
            ChatTime: FormatMessageTime(),
            ChatType: "message",
        }));
        $("#whatsapp-openedchat-message").val("");
        $("div.emojionearea-editor").data("emojioneArea").setText('');
    } else {
        QB.Phone.Notifications.Add("fab fa-whatsapp", "Whatsapp", "You can't send a empty message!", "#25D366", 1750);
    }
});

$(document).on('keypress', function (e) {
    if (OpenedChatData.number !== null) {
        if(e.which === 13){
            var Message = $("#whatsapp-openedchat-message").val();

            if (Message !== null && Message !== undefined && Message !== "") {
                // sent as typed: the server stores text and every phone shows it escaped
                $.post('https://pfm-phone/SendMessage', JSON.stringify({
                    ChatNumber: OpenedChatData.number,
                    ChatDate: GetCurrentDateKey(),
                    ChatMessage: Message,
                    ChatTime: FormatMessageTime(),
                    ChatType: "message",
                }));
                $("#whatsapp-openedchat-message").val("");
            } else {
                QB.Phone.Notifications.Add("fab fa-whatsapp", "Whatsapp", "You can't send a empty message!", "#25D366", 1750);
            }
        }
    }
});

$(document).on('click', '#send-location', function(e){
    e.preventDefault();

    $.post('https://pfm-phone/SendMessage', JSON.stringify({
        ChatNumber: OpenedChatData.number,
        ChatDate: GetCurrentDateKey(),
        ChatMessage: "Shared location",
        ChatTime: FormatMessageTime(),
        ChatType: "location",
    }));
});

$(document).on('click', '#send-image', function(e){
    e.preventDefault();
    let ChatNumber2 = OpenedChatData.number;
    $.post('https://pfm-phone/TakePhoto', JSON.stringify({}),function(url){
        if(url){
        $.post('https://pfm-phone/SendMessage', JSON.stringify({
        ChatNumber: ChatNumber2,
        ChatDate: GetCurrentDateKey(),
        ChatMessage: "Photo",
        ChatTime: FormatMessageTime(),
        ChatType: "picture",
        url : url
    }))}})
    QB.Phone.Functions.Close();
});

QB.Phone.Functions.SetupChatMessages = function(cData, NewChatData) {
    var esc = QB.Phone.Esc;
    function showPicture() {
        $(".whatsapp-openedchat-picture").css({"background-image": QB.Phone.CssUrl(OpenedChatPicture)});
    }
    function loadPicture() {
        $.post('https://pfm-phone/GetProfilePicture', JSON.stringify({
            number: OpenedChatData.number,
        }), function(picture){
            OpenedChatPicture = QB.Phone.SafeUrl(picture);
            showPicture();
        });
    }
    if (cData) {
        OpenedChatData.number = cData.number;

        if (OpenedChatPicture == null) {
            loadPicture();
        } else {
            showPicture();
        }

        $(".whatsapp-openedchat-name").html("<p>"+esc(cData.name)+"</p>");
        $(".whatsapp-openedchat-messages").html("");

        $.each(cData.messages, function(i, chat){
            var ChatDate = FormatChatDate(chat.date);
            var ChatDiv = '<div class="whatsapp-openedchat-messages-'+esc(i)+' unique-chat"><div class="whatsapp-openedchat-date">'+esc(ChatDate)+'</div></div>';

            $(".whatsapp-openedchat-messages").append(ChatDiv);

            $.each(cData.messages[i].messages, function(index, message){
                // every field is another player's (or an old stored row's): text and checked links only
                var Sender = "me";
                if (message.sender !== QB.Phone.Data.PlayerData.citizenid) { Sender = "other"; }
                var time = '<div class="whatsapp-openedchat-message-time">'+esc(message.time)+'</div>';
                var MessageElement = null;
                var data = message.data || {};
                if (message.type == "message") {
                    MessageElement = $('<div class="whatsapp-openedchat-message whatsapp-openedchat-message-'+Sender+'">'+esc(message.message)+time+'</div>');
                } else if (message.type == "location") {
                    var x = Number(data.x), y = Number(data.y);
                    if (isFinite(x) && isFinite(y)) {
                        MessageElement = $('<div class="whatsapp-openedchat-message whatsapp-openedchat-message-'+Sender+' whatsapp-shared-location"><span style="font-size: 1.2vh;"><i class="fas fa-map-marker-alt" style="font-size: 1vh;"></i> Location</span>'+time+'</div>');
                        MessageElement.attr('data-x', x).attr('data-y', y);
                    }
                } else if (message.type == "picture") {
                    var url = QB.Phone.SafeUrl(data.url, null);
                    if (url) {
                        MessageElement = $('<div class="whatsapp-openedchat-message whatsapp-openedchat-message-'+Sender+'"><img class="wppimage" style=" border-radius:4px; width: 100%; position:relative; z-index: 1; right:1px;height: auto;">'+time+'</div>');
                        MessageElement.attr('data-id', String(OpenedChatData.number || ""));
                        MessageElement.find('img.wppimage').attr('src', url);
                    }
                }
                if (MessageElement) {
                    $(".whatsapp-openedchat-messages-"+i).append(MessageElement).append('<div class="clearfix"></div>');
                }
            });
        });
        $('.whatsapp-openedchat-messages').animate({scrollTop: 9999}, 1);
    } else {
        OpenedChatData.number = NewChatData.number;
        if (OpenedChatPicture == null) {
            loadPicture();
        }

        $(".whatsapp-openedchat-name").html("<p>"+esc(NewChatData.name)+"</p>");
        $(".whatsapp-openedchat-messages").html("");
        var NewDate = new Date();
        var NewDateMonth = NewDate.getMonth();
        var NewDateDOM = NewDate.getDate();
        var NewDateYear = NewDate.getFullYear();
        var DateString = ""+NewDateDOM+"-"+(NewDateMonth+1)+"-"+NewDateYear;
        var ChatDiv = '<div class="whatsapp-openedchat-messages-'+DateString+' unique-chat"><div class="whatsapp-openedchat-date">TODAY</div></div>';

        $(".whatsapp-openedchat-messages").append(ChatDiv);
    }

    $('.whatsapp-openedchat-messages').animate({scrollTop: 9999}, 1);
}

$(document).on('click', '.whatsapp-shared-location', function(e){
    e.preventDefault();
    var messageCoords = {}
    messageCoords.x = $(this).data('x');
    messageCoords.y = $(this).data('y');

    $.post('https://pfm-phone/SharedLocation', JSON.stringify({
        coords: messageCoords,
    }))
});

$(document).on('click', '.wppimage', function(e){
    e.preventDefault();
    let source = $(this).attr('src')
    QB.Screen.popUp(source)
});

$(document).on('click', '#whatsapp-openedchat-message-extras', function(e){
    e.preventDefault();

    if (!ExtraButtonsOpen) {
        $(".whatsapp-extra-buttons").css({"display":"block"}).animate({
            left: 0+"vh"
        }, 250);
        ExtraButtonsOpen = true;
    } else {
        $(".whatsapp-extra-buttons").animate({
            left: -10+"vh"
        }, 250, function(){
            $(".whatsapp-extra-buttons").css({"display":"block"});
            ExtraButtonsOpen = false;
        });
    }
});
