import { toast } from '../../components/ui/toast'

import type { PersonalCredentialDeepLinkPayload, PersonalCredentialProvider } from '../../types'

/** Fired after the main process claims an OAuth grant, so an open section refetches. */
export const PERSONAL_CREDENTIALS_CHANGED = 'personal-credentials:changed'

const NAMES: Record<PersonalCredentialProvider, string> = {
  github: 'GitHub',
  linear: 'Linear',
  gmail: 'Gmail',
  'google-drive': 'Google Drive',
}

export function nameOf(provider: PersonalCredentialProvider): string {
  return NAMES[provider]
}

/** Global handler for the claimed nuphos://personal-credential deep link. */
export function announcePersonalCredential({
  provider,
  login,
  error,
}: PersonalCredentialDeepLinkPayload) {
  const name = nameOf(provider)

  if (login) {
    toast.success(`Connected ${name} as ${login}`)
  } else if (error === 'oauth_not_ready') {
    toast.error(
      `Couldn’t connect ${name}`,
      'This link expired or was started from another account.',
    )
  } else {
    toast.error(`Couldn’t connect ${name}`, 'Please try again.')
  }
  window.dispatchEvent(new Event(PERSONAL_CREDENTIALS_CHANGED))
}
