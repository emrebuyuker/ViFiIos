//
//  UniversityTableViewCell.swift
//  ViFi
//
//  Created by Emre BÜYÜKER on 14.05.2019.
//  Copyright © 2019 Emre BÜYÜKER. All rights reserved.
//

import UIKit

class UniversityTableViewCell: UITableViewCell {
    
    // MARK - Outles

    @IBOutlet weak var universityLabel: UILabel!
    
    // MARK - View Life Cycle
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    // MARK - Helpers Methods

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
    }
}
