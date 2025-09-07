//
//  HelperExtension.swift
//  Devgentic
//
//  Created by Raj Singh on 05/09/25.
//

import SwiftUI

extension Binding {
    func toNonOptional<T>(defaultValue: T) -> Binding<T> where Value == T? {
        Binding<T>(
            get: { self.wrappedValue ?? defaultValue },
            set: { self.wrappedValue = $0 }
        )
    }
}
