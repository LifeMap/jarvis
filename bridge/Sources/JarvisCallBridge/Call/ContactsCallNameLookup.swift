import Contacts
import Foundation

enum ContactsCallNameLookup {
    static func displayName(forPhone phone: String) -> String? {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            store.requestAccess(for: .contacts) { _, _ in }
            return nil
        }
        if status != .authorized { return nil }
        let number = CNPhoneNumber(stringValue: phone)
        let predicate = CNContact.predicateForContacts(matching: number)
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        guard let contact = contacts.first else { return nil }
        let name = [contact.familyName, contact.givenName].filter { !$0.isEmpty }.joined(separator: "")
        if !name.isEmpty { return name }
        return contact.organizationName.isEmpty ? nil : contact.organizationName
    }
}
