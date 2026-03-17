const legacyCopy = (text) =>
  new Promise((resolve, reject) => {
    const textarea = document.createElement("textarea")
    textarea.value = text
    textarea.setAttribute("readonly", "")
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    textarea.setSelectionRange(0, text.length)
    const ok = document.execCommand("copy")
    document.body.removeChild(textarea)
    return ok ? resolve() : reject(new Error("execCommand copy failed"))
  })

const legacyCopyRich = (plainText, htmlText) =>
  new Promise((resolve, reject) => {
    const textarea = document.createElement("textarea")
    textarea.value = plainText
    textarea.setAttribute("readonly", "")
    textarea.style.position = "fixed"
    textarea.style.opacity = "0"
    document.body.appendChild(textarea)
    textarea.select()
    textarea.setSelectionRange(0, plainText.length)

    const onCopy = (event) => {
      if (!event.clipboardData) return
      event.preventDefault()
      event.clipboardData.setData("text/plain", plainText)
      event.clipboardData.setData("text/html", htmlText)
    }

    document.addEventListener("copy", onCopy)
    try {
      const ok = document.execCommand("copy")
      return ok ? resolve() : reject(new Error("execCommand copy failed"))
    } finally {
      document.removeEventListener("copy", onCopy)
      document.body.removeChild(textarea)
    }
  })

const tryCopyRich = async (plainText, htmlText) => {
  if (!window.isSecureContext) return false
  if (!navigator.clipboard?.write) return false
  const ClipboardItemCtor = window.ClipboardItem
  if (!ClipboardItemCtor) return false

  try {
    const item = new ClipboardItemCtor({
      "text/plain": new Blob([plainText], {type: "text/plain"}),
      "text/html": new Blob([htmlText], {type: "text/html"}),
    })
    await navigator.clipboard.write([item])
    return true
  } catch (error) {
    console.warn("Clipboard write failed, falling back", error)
    return false
  }
}

export async function copyRichTextWithFallback(plainText, htmlText, options) {
  const promptLabel = options?.promptLabel ?? "Copy the message text and press Ctrl+C / Cmd+C"
  let copied = false

  copied = await tryCopyRich(plainText, htmlText)

  if (!copied && navigator.clipboard?.writeText && window.isSecureContext) {
    try {
      await navigator.clipboard.writeText(plainText)
      copied = true
    } catch (error) {
      console.warn("Clipboard writeText failed, using fallback", error)
    }
  }

  if (!copied) {
    try {
      await legacyCopyRich(plainText, htmlText)
      copied = true
    } catch (legacyError) {
      console.warn("Legacy rich clipboard copy failed", legacyError)
      try {
        await legacyCopy(plainText)
        copied = true
      } catch (plainLegacyError) {
        console.warn("Legacy clipboard copy failed", plainLegacyError)
        window.prompt(promptLabel, plainText)
      }
    }
  }

  return copied
}

