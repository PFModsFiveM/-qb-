var CurrentTwitterTab = "twitter-home"
var HashtagOpen = false;
var MinimumTrending = 100;

$(document).on('click', '.twitter-header-tab', function(e){
    e.preventDefault();

    var PressedTwitterTab = $(this).data('twittertab');
    var PreviousTwitterTabObject = $('.twitter-header').find('[data-twittertab="'+CurrentTwitterTab+'"]');

    if (PressedTwitterTab !== CurrentTwitterTab) {
        $(this).addClass('selected-twitter-header-tab');
        $(PreviousTwitterTabObject).removeClass('selected-twitter-header-tab');

        $("."+CurrentTwitterTab+"-tab").css({"display":"none"});
        $("."+PressedTwitterTab+"-tab").css({"display":"block"});

        if (PressedTwitterTab === "twitter-mentions") {
            $.post('https://pfm-phone/ClearMentions');
        }

        if (PressedTwitterTab == "twitter-home") {
            $.post('https://pfm-phone/GetTweets', JSON.stringify({}), function(Tweets){
                QB.Phone.Notifications.LoadTweets(Tweets);
            });
        }

        CurrentTwitterTab = PressedTwitterTab;

        if (HashtagOpen) {
            event.preventDefault();

            $(".twitter-hashtag-tweets").css({"left": "30vh"});
            $(".twitter-hashtags").css({"left": "0vh"});
            $(".twitter-new-tweet").css({"display":"block"});
            $(".twitter-hashtags").css({"display":"block"});
            HashtagOpen = false;
        }
    } else if (CurrentTwitterTab == "twitter-hashtags" && PressedTwitterTab == "twitter-hashtags") {
        if (HashtagOpen) {
            event.preventDefault();

            $(".twitter-hashtags").css({"display":"block"});
            $(".twitter-hashtag-tweets").animate({
                left: 30+"vh"
            }, 150);
            $(".twitter-hashtags").animate({
                left: 0+"vh"
            }, 150);
            HashtagOpen = false;
        }
    } else if (CurrentTwitterTab == "twitter-home" && PressedTwitterTab == "twitter-home") {
        event.preventDefault();

        $.post('https://pfm-phone/GetTweets', JSON.stringify({}), function(Tweets){
            QB.Phone.Notifications.LoadTweets(Tweets);
        });
    } else if (CurrentTwitterTab == "twitter-mentions" && PressedTwitterTab == "twitter-mentions") {
        event.preventDefault();

        $.post('https://pfm-phone/GetMentionedTweets', JSON.stringify({}), function(MentionedTweets){
            QB.Phone.Notifications.LoadMentionedTweets(MentionedTweets)
        })
    }
});

$(document).on('click', '.twitter-new-tweet', function(e){
    e.preventDefault();

    QB.Phone.Animations.TopSlideDown(".twitter-new-tweet-tab", 450, 0);
});

$(document).on('click', '#take-pic', function (e) {
    e.preventDefault();
    $.post('https://pfm-phone/TakePhoto', JSON.stringify({}),function(url){
        if(url){
            $('#tweet-new-url').val(url)
        }
    })
    QB.Phone.Functions.Close();
})

// One tweet as a jQuery element. Tweets come from every player: names, time and links go in as text
// or as checked attributes, the message through FormatTwitterMessage (escaped first).
function TweetElement(Tweet, withReply) {
    var esc = QB.Phone.Esc;
    var name = String(Tweet.firstName || '') + ' ' + String(Tweet.lastName || '');
    var handle = '@' + name.replace(" ", "_");
    var TimeAgo = moment(Tweet.date).format('MM/DD/YYYY hh:mm');
    var html = '<div class="twitter-tweet">' +
        (withReply ? '<div class="tweet-reply"><i class="fas fa-reply"></i></div>' : '') +
        '<div class="tweet-tweeter">' + esc(name) + ' &nbsp;<span>' + esc(handle) + ' &middot; ' + esc(TimeAgo) + '</span></div>' +
        '<div class="tweet-message">' + QB.Phone.Functions.FormatTwitterMessage(Tweet.message) + '</div>' +
        '<div class="twt-img" style="top: 1vh;"><img class="tweeter-image"></div>' +
        '</div>';
    var el = $(html);
    el.find('img.tweeter-image').attr('src', Tweet.picture === "default" ? "./img/default.png" : QB.Phone.SafeUrl(Tweet.picture));
    var url = Tweet.url ? QB.Phone.SafeUrl(Tweet.url, null) : null;
    if (url) {
        var img = $('<img class="image" style=" border-radius:4px; width: 70%; position:relative; z-index: 1; left:52px; margin:.6rem .5rem .6rem 1rem;height: auto; padding-bottom: 15px;">').attr('src', url);
        el.find('.tweet-message').after(img);
    }
    if (withReply) {
        el.attr('data-twthandler', handle);
        el.attr('data-twtcid', String(Tweet.citizenid || ''));
        el.attr('data-twtid', String(Tweet.tweetId || ''));
    }
    return el;
}

QB.Phone.Notifications.LoadTweets = function(Tweets) {
    if (Tweets !== null && Tweets !== undefined && Tweets !== "" && Tweets.length > 0) {
        Tweets = Tweets.slice().reverse();
        $(".twitter-home-tab").html("");
        $.each(Tweets, function(i, Tweet){
            $(".twitter-home-tab").append(TweetElement(Tweet, true));
        });
    }
}

$(document).on('click','#twt-delete-click',function(e){
    e.preventDefault();
    let source = $('.twitter-tweet').data('twtid')
    $(this).parent().parent().parent().parent().remove()
    $.post('https://pfm-phone/DeleteTweet', JSON.stringify({id: source}))
})

$(document).on('click', '.tweet-reply', function(e){
    e.preventDefault();
    var TwtName = $(this).parent().data('twthandler');
    $('#tweet-new-url').val("");
    $("#tweet-new-message").val(TwtName + " ");
    QB.Phone.Animations.TopSlideDown(".twitter-new-tweet-tab", 450, 0);
});

QB.Phone.Notifications.LoadMentionedTweets = function(Tweets) {
    $('#tweet-new-url').val("");
    if (Tweets && Tweets.length > 0) {
        Tweets = Tweets.slice().reverse();
        $(".twitter-mentions-tab").html("");
        $.each(Tweets, function(i, Tweet){
            $(".twitter-mentioned-tweet").css({"background-color":"#F5F8FA"});
            $(".twitter-mentions-tab").append(TweetElement(Tweet, false));
        });
    }
}

// The message as HTML: escaped, then @mentions and #hashtags (letters, digits, _ and - only) made
// clickable. (It used to put the tag text into quoted attributes unescaped.)
QB.Phone.Functions.FormatTwitterMessage = function(TwitterMessage) {
    var text = QB.Phone.Esc(TwitterMessage);
    if (text === '') return '';
    return text
        .replace(/(^|\s)@([A-Za-z0-9_\-]+)/g, function(m, pre, tag) {
            return pre + "<span class='mentioned-tag' data-mentiontag='@" + tag + "'>@" + tag + "</span>";
        })
        .replace(/(^|\s)#([A-Za-z0-9_\-]+)/g, function(m, pre, tag) {
            return pre + "<span class='hashtag-tag-text' data-hashtag='" + tag + "'>#" + tag + "</span>";
        });
}

$(document).on('click', '#send-tweet', function(e){
    e.preventDefault();
    var TweetMessage = $("#tweet-new-message").val();
    var imageURL = $('#tweet-new-url').val()
    if (TweetMessage != "") {
        var CurrentDate = new Date();
        $.post('https://pfm-phone/PostNewTweet', JSON.stringify({
            Message: TweetMessage,
            Date: CurrentDate,
            Picture: QB.Phone.Data.MetaData.profilepicture,
            url: imageURL
        }), function(Tweets){
            QB.Phone.Notifications.LoadTweets(Tweets);
        });
        $.post('https://pfm-phone/GetHashtags', JSON.stringify({}), function(Hashtags){
            QB.Phone.Notifications.LoadHashtags(Hashtags)
        })
        QB.Phone.Animations.TopSlideUp(".twitter-new-tweet-tab", 450, -120);
    } else {
        QB.Phone.Notifications.Add("fab fa-twitter", "Twitter", "Fill a message!", "#1DA1F2");
    };
    $('#tweet-new-url').val("");
    $("#tweet-new-message").val("");
});

$(document).on('click', '#cancel-tweet', function(e){
    e.preventDefault();
    $('#tweet-new-url').html("");
    QB.Phone.Animations.TopSlideUp(".twitter-new-tweet-tab", 450, -120);
});

$(document).on('click', '.image', function(e){
    e.preventDefault();
    let source = $(this).attr('src')
    QB.Screen.popUp(source)
});

$(document).on('click', '.mentioned-tag', function(e){
    e.preventDefault();
    CopyMentionTag(this);
});

$(document).on('click', '.hashtag-tag-text', function(e){
    e.preventDefault();
    if (!HashtagOpen) {
        var Hashtag = $(this).data('hashtag');
        var PreviousTwitterTabObject = $('.twitter-header').find('[data-twittertab="'+CurrentTwitterTab+'"]');

        $("#twitter-hashtags").addClass('selected-twitter-header-tab');
        $(PreviousTwitterTabObject).removeClass('selected-twitter-header-tab');

        $("."+CurrentTwitterTab+"-tab").css({"display":"none"});
        $(".twitter-hashtags-tab").css({"display":"block"});

        $.post('https://pfm-phone/GetHashtagMessages', JSON.stringify({hashtag: Hashtag}), function(HashtagData){
            QB.Phone.Notifications.LoadHashtagMessages(HashtagData.messages);
        });

        $(".twitter-hashtag-tweets").css({"display":"block", "left":"30vh"});
        $(".twitter-hashtag-tweets").css({"left": "0vh"});
        $(".twitter-hashtags").css({"left": "-30vh"});
        $(".twitter-hashtags").css({"display":"none"});
        HashtagOpen = true;

        CurrentTwitterTab = "twitter-hashtags";
    }
});

function CopyMentionTag(elem) {
    var $temp = $("<input>");
    $("body").append($temp);
    $temp.val($(elem).data('mentiontag')).select();
    QB.Phone.Notifications.Add("fab fa-twitter", "Twitter", $(elem).data('mentiontag')+ " copied!", "rgb(27, 149, 224)", 1250);
    document.execCommand("copy");
    $temp.remove();
}

QB.Phone.Notifications.LoadHashtags = function(hashtags) {
    if (hashtags !== null && hashtags !== undefined) {
        $(".twitter-hashtags").html("");
        var n = 0;
        $.each(hashtags, function(i, hashtag){
            if (!hashtag || !hashtag.messages) return;
            n = n + 1;
            var TweetHandle = hashtag.messages.length > 1 ? "Tweets" : "Tweet";
            var status = hashtag.messages.length >= MinimumTrending ? "Trending in City" : "Not trending in City";
            var Elem = $('<div class="twitter-hashtag"><div class="twitter-hashtag-status"></div> <div class="twitter-hashtag-tag"></div> <div class="twitter-hashtag-messages"></div> </div>');
            Elem.attr('id', 'tag-' + n);
            Elem.find('.twitter-hashtag-status').text(status);
            Elem.find('.twitter-hashtag-tag').text('#' + hashtag.hashtag);
            Elem.find('.twitter-hashtag-messages').text(hashtag.messages.length + ' ' + TweetHandle);
            $(".twitter-hashtags").append(Elem);
            Elem.data('tagData', hashtag);
        });
    }
}

QB.Phone.Notifications.LoadHashtagMessages = function(Tweets) {
    if (Tweets !== null && Tweets !== undefined && Tweets !== "" && Tweets.length > 0) {
        Tweets = Tweets.slice().reverse();
        $(".twitter-hashtag-tweets").html("");
        $.each(Tweets, function(i, Tweet){
            $(".twitter-hashtag-tweets").append(TweetElement(Tweet, false));
        });
    }
}


$(document).on('click', '.twitter-hashtag', function(event){
    event.preventDefault();

    var TweetData = $(this).data('tagData');
    if (!TweetData) return;

    QB.Phone.Notifications.LoadHashtagMessages(TweetData.messages);

    $(".twitter-hashtag-tweets").css({"display":"block", "left":"30vh"});
    $(".twitter-hashtag-tweets").animate({
        left: 0+"vh"
    }, 150);
    $(".twitter-hashtags").animate({
        left: -30+"vh"
    }, 150, function(){
        $(".twitter-hashtags").css({"display":"none"});
    });
    HashtagOpen = true;
});
