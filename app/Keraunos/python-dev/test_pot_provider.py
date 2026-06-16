import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))


def test_provider_class_is_well_formed():
    import keraunos_youtube_pot as m
    from yt_dlp.extractor.youtube.pot.provider import PoTokenProvider
    assert issubclass(m.KeraunosPoTokenProviderPTP, PoTokenProvider)
    assert m.KeraunosPoTokenProviderPTP.__name__.endswith("PTP")


def test_provider_registers_with_pot_framework():
    import keraunos_youtube_pot as m
    from yt_dlp.extractor.youtube.pot._registry import _pot_providers
    assert any(cls is m.KeraunosPoTokenProviderPTP for cls in _pot_providers.value.values())
