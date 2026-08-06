"""Renders text into an image, OCRs it back, verifies the round trip.
Run: python ocr_demo.py
"""
from PIL import Image, ImageDraw, ImageFont
import pytesseract

EXPECTED = "THE QUICK BROWN FOX"


def make_image(path="ocr_input.png"):
    img = Image.new("RGB", (800, 120), "white")
    draw = ImageDraw.Draw(img)
    draw.text((20, 20), EXPECTED, fill="black", font=ImageFont.load_default(size=60))
    img.save(path)
    return path


def main():
    path = make_image()
    text = pytesseract.image_to_string(Image.open(path)).strip()
    print(f"expected: {EXPECTED}")
    print(f"ocr read: {text}")
    if text != EXPECTED:
        raise SystemExit("OCR round trip FAILED")
    print("OCR round trip OK")


if __name__ == "__main__":
    main()
