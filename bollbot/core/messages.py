"""Tamil and English advisory text.

Short, fixed templates so that the app can also ship pre-recorded audio
for each one. NOTE: Tamil wording must be reviewed by a native speaker
and an agriculture officer before the farmer usability test (E9).
"""
from __future__ import annotations

from .models import Advisory, AdvisoryType

_SAFETY_EN = ("Use only a CIB&RC-registered product at label dose; "
              "follow the label pre-harvest interval and wear PPE.")
_SAFETY_TA = ("பதிவு செய்யப்பட்ட மருந்தை லேபிள் அளவில் மட்டும் பயன்படுத்தவும்; "
              "அறுவடைக்கு முந்தைய இடைவெளியைப் பின்பற்றி, பாதுகாப்பு உடை அணியவும்.")

TEMPLATES: dict[AdvisoryType, tuple[str, str]] = {
    AdvisoryType.PICK_NOW: (
        "Rain likely within {hours} hours. Pick these segments first: {segments}.",
        "அடுத்த {hours} மணி நேரத்தில் மழை வாய்ப்பு உள்ளது. இந்தப் பகுதிகளை முதலில் பறிக்கவும்: {segments}.",
    ),
    AdvisoryType.PICK_LIST: (
        "Ready to pick: {segments}.",
        "பறிக்கத் தயாரான பகுதிகள்: {segments}.",
    ),
    AdvisoryType.PEST_ETL: (
        "{pest} has crossed its economic threshold. Consult your agriculture officer. " + _SAFETY_EN,
        "{pest} பொருளாதார சேத நிலையைத் தாண்டியுள்ளது. வேளாண் அலுவலரை அணுகவும். " + _SAFETY_TA,
    ),
    AdvisoryType.SPOT_TREAT: (
        "{pest} has crossed its threshold. Locations: {segments}. Never spray the whole field: "
        "treat neighbouring plants first, then the infested plants at the stem base. "
        "Do not touch or shake infested plants. " + _SAFETY_EN,
        "{pest} சேத நிலையைத் தாண்டியுள்ளது. இடங்கள்: {segments}. முழு வயலுக்கும் தெளிக்க வேண்டாம்: "
        "முதலில் அருகிலுள்ள செடிகளுக்கும், பின்னர் பாதிக்கப்பட்ட செடிகளின் தண்டு அடிப்பகுதிக்கும் மட்டும் தெளிக்கவும். "
        "பாதிக்கப்பட்ட செடிகளைத் தொடவோ அசைக்கவோ வேண்டாம். " + _SAFETY_TA,
    ),
    AdvisoryType.PEST_ALERT: (
        "Signs of {pest}. Remove affected plants; spraying will not cure it.",
        "{pest} அறிகுறிகள் உள்ளன. பாதிக்கப்பட்ட செடிகளை அகற்றவும்; மருந்து தெளிப்பதால் குணமாகாது.",
    ),
    AdvisoryType.SPRAY_BLOCKED: (
        "{pest} has crossed its threshold, but cotton is ready for picking. "
        "Pick first; check the label pre-harvest interval before any spray.",
        "{pest} சேத நிலையைத் தாண்டியுள்ளது, ஆனால் பருத்தி பறிக்கத் தயாராக உள்ளது. "
        "முதலில் பறிக்கவும்; தெளிப்பதற்கு முன் லேபிளில் உள்ள அறுவடைக்கு முந்தைய இடைவெளியைச் சரிபார்க்கவும்.",
    ),
}


# Shown when a threshold is crossed but no location has been confirmed yet (QA bug 7).
NO_SEGMENTS_EN = "not yet marked - check the plants in your sample"
NO_SEGMENTS_TA = "இன்னும் குறிக்கப்படவில்லை - நீங்கள் மாதிரி எடுத்த செடிகளைச் சரிபார்க்கவும்"


def fill_text(adv: Advisory, pest_en: str = "", pest_ta: str = "",
              max_segments: int = 8, hours: int = 48) -> Advisory:
    """Fill text_en / text_ta on an advisory in place and return it.

    hours: the rain-alert window, passed from thresholds.yaml (QA bug 15).
    """
    segs = adv.segments[:max_segments]
    more = " …" if len(adv.segments) > max_segments else ""
    seg_en = ", ".join(segs) + more if segs else NO_SEGMENTS_EN
    seg_ta = ", ".join(segs) + more if segs else NO_SEGMENTS_TA
    en, ta = TEMPLATES[adv.type]
    adv.text_en = en.format(segments=seg_en, pest=pest_en, hours=hours)
    adv.text_ta = ta.format(segments=seg_ta, pest=pest_ta or pest_en, hours=hours)
    return adv
